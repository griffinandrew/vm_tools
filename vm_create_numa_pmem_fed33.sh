#!/usr/bin/env bash
# =============================================================================
# create-numa-vm.sh
# WORKING  THIS SCRIPT ADDS PMEM AS A NUMA DEVICE SUCCESSFULLY!!!
# Creates a KVM/libvirt VM with two NUMA nodes:
#   Node 0 — DRAM  (vCPUs live here)
#   Node 1 — PMEM  (backed by a host devdax device, e.g. /dev/dax0.0)
#
# Strategy:
#   Phase 1 — virt-install with plain RAM only (no NUMA args) to avoid the
#              "-machine memory-backend vs -numa memdev" conflict.
#   Phase 2 — After install, inject NUMA + NVDIMM XML via virsh define,
#              then start the VM.
#
# Usage:
#   sudo ./create-numa-vm.sh -n <VM_NAME> -r <DRAM_MiB> -c <VCPUS> -d <DEV_DAX_PATH>
#
# Example:
#   sudo ./create-numa-vm.sh -n numa-vm -r 8192 -c 4 -d /dev/dax0.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
warn()    { echo "[WARN]  $*"; }
success() { echo "[OK]    $*"; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 -n <VM_NAME> -r <DRAM_MiB> -c <VCPUS> -d <DEV_DAX_PATH>

  -n  VM name
  -r  DRAM size in MiB  (guest NUMA node 0)
  -c  vCPU count        (all assigned to node 0)
  -d  Host devdax path  (e.g. /dev/dax0.0)

PMEM size is detected automatically from the devdax device.

Example:
  $0 -n numa-vm -r 8192 -c 4 -d /dev/dax0.0
EOF
    exit 1
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
VM_NAME=""
RAM_MB=""
VCPUS=""
PMEM_PATH=""

while getopts ":n:r:c:d:" opt; do
  case $opt in
    n) VM_NAME="$OPTARG" ;;
    r) RAM_MB="$OPTARG" ;;
    c) VCPUS="$OPTARG" ;;
    d) PMEM_PATH="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$VM_NAME" || -z "$RAM_MB" || -z "$VCPUS" ]] && usage

# -----------------------------------------------------------------------------
# STEP 0 — Detect devdax size
# -----------------------------------------------------------------------------
info "Detecting size of $PMEM_PATH..."

[[ -c "$PMEM_PATH" ]] || die "$PMEM_PATH is not a character device. Check ndctl/daxctl setup."

DAX_NAME=$(basename "$PMEM_PATH")

# Try daxctl first (most reliable), fall back to ndctl
ACTUAL_DAX_SIZE=$(daxctl list -d "$DAX_NAME" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['size'])" 2>/dev/null) \
    || true

if [[ -z "$ACTUAL_DAX_SIZE" || "$ACTUAL_DAX_SIZE" == "0" ]]; then
    # Fallback: ndctl list
    ACTUAL_DAX_SIZE=$(ndctl list -N 2>/dev/null \
        | python3 -c "
import sys, json
ns = json.load(sys.stdin)
if isinstance(ns, dict): ns = [ns]
for n in ns:
    if n.get('chardev','') == '${DAX_NAME}' or n.get('blockdev','') == '${DAX_NAME}':
        print(n['size']); break
" 2>/dev/null) || true
fi

[[ -z "$ACTUAL_DAX_SIZE" || "$ACTUAL_DAX_SIZE" == "0" ]] && \
    die "Could not detect size of $PMEM_PATH. Is daxctl/ndctl installed and the namespace configured?"

PMEM_MB=$(( ACTUAL_DAX_SIZE / 1024 / 1024 ))
success "Detected DAX size: $ACTUAL_DAX_SIZE bytes (${PMEM_MB} MiB)"

# Verify MiB alignment — QEMU requires exact byte match between -m total and NUMA sum
PMEM_BYTES_CHECK=$(( PMEM_MB * 1024 * 1024 ))
if [[ "$PMEM_BYTES_CHECK" != "$ACTUAL_DAX_SIZE" ]]; then
    warn "DAX size ($ACTUAL_DAX_SIZE bytes) is not MiB-aligned."
    warn "Rounding down to ${PMEM_MB} MiB (${PMEM_BYTES_CHECK} bytes). This may cause QEMU errors."
    warn "Ideal fix: recreate the namespace with an MiB-aligned size."
fi

# Check devdax mode
DAX_MODE=$(daxctl list -D 2>/dev/null | python3 -c "
import sys, json
try:
    devs = json.load(sys.stdin)
    if isinstance(devs, dict): devs = [devs]
    for d in devs:
        if d.get('chardev') == '${DAX_NAME}':
            print(d.get('mode', 'unknown'))
            break
except:
    pass
" 2>/dev/null || echo "unknown")

if [[ "$DAX_MODE" == "system-ram" ]]; then
    die "$PMEM_PATH is in system-ram mode — QEMU cannot open it as devdax.
  Options:
    1. Use a namespace already in devdax mode
    2. sudo ndctl create-namespace --mode=devdax --size=<size> --map=dev"
fi

info "Device mode: ${DAX_MODE:-devdax} ✓"

# -----------------------------------------------------------------------------
# Derived sizes
# -----------------------------------------------------------------------------
VCPU_LAST=$(( VCPUS - 1 ))
TOTAL_MB=$(( RAM_MB + PMEM_MB ))

# libvirt maxMemory must cover: DRAM + PMEM (cell) + PMEM (nvdimm device) + headroom
# nvdimm label area (2 MiB) is subtracted from usable PMEM inside the guest
LABEL_SIZE_KIB=2048
MAX_MEM_MIB=$(( RAM_MB + PMEM_MB * 2 + 8192 ))

DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
DISK_SIZE="30G"
TMP_XML="/tmp/${VM_NAME}-numa.xml"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  VM Type  : NUMA — PMEM as memory-only node (node 1)"
echo "  VM Name  : $VM_NAME"
echo "  DRAM     : ${RAM_MB} MiB  → guest NUMA node 0 (CPUs 0-${VCPU_LAST})"
echo "  PMEM     : ${PMEM_MB} MiB  → guest NUMA node 1 (backed by $PMEM_PATH)"
echo "  Total -m : ${TOTAL_MB} MiB"
echo "  MaxMem   : ${MAX_MEM_MIB} MiB"
echo "  vCPUs    : $VCPUS"
echo "  Disk     : $DISK_PATH ($DISK_SIZE)"
echo "============================================================"
echo ""
read -r -p "Continue? (y/n): " choice
[[ "$choice" =~ ^[Yy]$ ]] || exit 0

# -----------------------------------------------------------------------------
# STEP 1 — Permissions
# -----------------------------------------------------------------------------
info "Setting ACL on $PMEM_PATH for libvirt-qemu / kvm..."
sudo setfacl -m u:libvirt-qemu:rw "$PMEM_PATH"
sudo setfacl -m g:kvm:rw          "$PMEM_PATH"
getfacl "$PMEM_PATH" 2>/dev/null | grep -E "libvirt-qemu|kvm" \
    && success "ACL set." \
    || warn "Could not verify ACL — continuing anyway."

# -----------------------------------------------------------------------------
# STEP 2 — Disk image
# -----------------------------------------------------------------------------
if [[ -f "$DISK_PATH" ]]; then
    info "Disk image already exists, skipping creation."
else
    info "Creating ${DISK_SIZE} disk image at $DISK_PATH..."
    sudo qemu-img create -f qcow2 "$DISK_PATH" "$DISK_SIZE"
    success "Disk created."
fi

# -----------------------------------------------------------------------------
# STEP 3 — Install VM (plain RAM, no NUMA — avoids the memdev conflict)
# -----------------------------------------------------------------------------
if sudo virsh domstate "$VM_NAME" &>/dev/null; then
    info "VM '$VM_NAME' already exists — skipping install."
else
    info "Phase 1: Installing VM with plain RAM (NUMA will be added after install)..."
    echo "    Complete the OS installation, shut down the guest, then press ENTER here."
    echo ""

    sudo virt-install \
      --name        "$VM_NAME" \
      --os-variant  fedora33 \
      --vcpus       "$VCPUS" \
      --memory      "$RAM_MB" \
      --cpu         host-passthrough \
      --machine     q35 \
      --location    'https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/33/Server/x86_64/os/' \
      --disk        path="$DISK_PATH",format=qcow2 \
      --network     bridge=virbr0 \
      --graphics    none \
      --console     pty,target_type=serial \
      --extra-args  'console=ttyS0,115200n8 serial' \
      --wait -1 || true   # virt-install exits non-zero after install+shutdown; that's fine
fi

echo ""
read -r -p "Confirm the VM is fully shut down (virsh domstate $VM_NAME should say 'shut off'), then press ENTER..."

# Double-check it's really off
VM_STATE=$(sudo virsh domstate "$VM_NAME" 2>/dev/null || echo "unknown")
if [[ "$VM_STATE" != "shut off" ]]; then
    warn "VM state is '$VM_STATE', not 'shut off'."
    warn "Forcibly shutting down..."
    sudo virsh destroy "$VM_NAME" 2>/dev/null || true
    sleep 3
fi

# -----------------------------------------------------------------------------
# STEP 4 — Extract current XML and inject NUMA + NVDIMM
# -----------------------------------------------------------------------------
info "Phase 2: Injecting NUMA topology + NVDIMM into VM XML..."

sudo virsh dumpxml "$VM_NAME" > "$TMP_XML"

# Use Python to surgically modify the XML (avoids fragile sed/awk on XML)
python3 <<PYEOF
import xml.etree.ElementTree as ET
import sys, copy, re

ET.register_namespace('', '')
tree = ET.parse('${TMP_XML}')
root = tree.getroot()

def ns_strip(tag):
    return re.sub(r'\{.*?\}', '', tag)

# ── 1. maxMemory ──────────────────────────────────────────────────────────────
# Remove existing maxMemory if present
for el in root.findall('maxMemory'):
    root.remove(el)

max_mem = ET.Element('maxMemory')
max_mem.set('slots', '16')
max_mem.set('unit',  'MiB')
max_mem.text = '${MAX_MEM_MIB}'
root.insert(0, max_mem)

# ── 2. <memory> and <currentMemory> — set to DRAM+PMEM total ─────────────────
for tag in ('memory', 'currentMemory'):
    el = root.find(tag)
    if el is None:
        el = ET.SubElement(root, tag)
    el.set('unit', 'MiB')
    #el.text = '${TOTAL_MB}'
    # Set to just DRAM size — total memory is defined by maxMemory, and the
    # PMEM is added as a separate NUMA cell + nvdimm device, so it doesn't need
    # to be included in the main <memory> element.
    el.text = '${RAM_MB}'



# ── 3. <cputune> — pin each vCPU to a physical CPU ───────────────────────────
# Remove existing <cputune> if any
for ct in root.findall('cputune'):
    root.remove(ct)

cputune = ET.Element('cputune')
for i in range(${VCPUS}):
    pin = ET.SubElement(cputune, 'vcpupin')
    pin.set('vcpu',   str(i))
    pin.set('cpuset', str(i))

# Insert cputune after <vcpu> element
vcpu_el = root.find('vcpu')
vcpu_idx = list(root).index(vcpu_el) if vcpu_el is not None else 1
root.insert(vcpu_idx + 1, cputune)


# ── 3. <cpu> — add <numa> cell topology ──────────────────────────────────────
cpu_el = root.find('cpu')
if cpu_el is None:
    cpu_el = ET.SubElement(root, 'cpu')
    cpu_el.set('mode', 'host-passthrough')

# Remove existing <numa> if any
for numa_el in cpu_el.findall('numa'):
    cpu_el.remove(numa_el)

numa_el = ET.SubElement(cpu_el, 'numa')

cell0 = ET.SubElement(numa_el, 'cell')
cell0.set('id',     '0')
cell0.set('cpus',   '0-${VCPU_LAST}')
cell0.set('memory', '${RAM_MB}')
cell0.set('unit',   'MiB')

cell1 = ET.SubElement(numa_el, 'cell')
cell1.set('id',     '1')
# NOTE: no 'cpus' attribute — omitting it entirely is correct for a
# memory-only NUMA node. Setting cpus='' causes libvirt to reject the
# XML with "Failed to parse bitmap ''"
#cell1.set('memory', '${PMEM_MB}')
#set to be 1gb hard and reconfigure in guest for pmem to be bound to node 1
cell1.set('memory', '1024')
cell1.set('unit',   'MiB')

# ── 4. <devices> — add NVDIMM backed by devdax ───────────────────────────────
devices_el = root.find('devices')
if devices_el is None:
    devices_el = ET.SubElement(root, 'devices')

# Remove any existing nvdimm memory devices to avoid duplication
for mem_el in devices_el.findall('memory'):
    if mem_el.get('model') == 'nvdimm':
        devices_el.remove(mem_el)

nvdimm = ET.SubElement(devices_el, 'memory')
nvdimm.set('model',  'nvdimm')
nvdimm.set('access', 'shared')

src = ET.SubElement(nvdimm, 'source')
path_el = ET.SubElement(src, 'path')
path_el.text = '${PMEM_PATH}'
align_el = ET.SubElement(src, 'alignsize')
align_el.set('unit', 'KiB')
align_el.text = '16384'  # 16 MiB alignment recommended for PMEM
ET.SubElement(src, 'pmem')

tgt = ET.SubElement(nvdimm, 'target')
size_el = ET.SubElement(tgt, 'size')
size_el.set('unit', 'MiB')
size_el.text = '${PMEM_MB}'
node_el = ET.SubElement(tgt, 'node')
node_el.text = '1'
label_el = ET.SubElement(tgt, 'label')
label_sz = ET.SubElement(label_el, 'size')
label_sz.set('unit', 'KiB')
label_sz.text = '${LABEL_SIZE_KIB}'

# ── 5. Write out ──────────────────────────────────────────────────────────────
tree.write('${TMP_XML}', encoding='unicode', xml_declaration=True)
print('XML patched successfully.')
PYEOF

success "XML patched. Defining updated domain..."
sudo virsh define "$TMP_XML"
success "Domain redefined with NUMA topology."

# -----------------------------------------------------------------------------
# STEP 5 — Start VM
# -----------------------------------------------------------------------------
info "Starting VM '$VM_NAME'..."
sudo virsh start "$VM_NAME"
success "VM started!"

# -----------------------------------------------------------------------------
# STEP 6 — Verify
# -----------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "  VM '$VM_NAME' is running."
echo ""
echo "  Connect:   sudo virsh console $VM_NAME"
echo ""
echo "  Inside the guest, verify NUMA:"
echo "    numactl --hardware"
echo "    numactl -H"
echo "    cat /sys/devices/system/node/node*/meminfo"
echo ""
echo "  Verify PMEM/NVDIMM:"
echo "    ndctl list"
echo "    dmesg | grep -iE 'pmem|nvdimm|nfit'"
echo ""
echo "  Use PMEM explicitly:"
echo "    numactl --membind=1 --cpunodebind=0 <your_application>"
echo ""
echo "  Online PMEM as DAX-capable RAM inside guest:"
echo "    sudo daxctl list"
echo "    sudo ndctl"
echo "    sudo ndctl destroy-namespace namespace0.0 -f"
echo "    sudo ndctl create-namespace -r region0 --mode=devdax --align=2M"
echo "    sudo daxctl reconfigure-device dax0.0 --mode=system-ram"
echo "    sudo daxctl list"
echo "    maybe also need to online it if not auto-online:"
echo "    sudo ndctl online-memory nmem0"
echo "============================================================"




