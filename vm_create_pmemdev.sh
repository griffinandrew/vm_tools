#!/bin/bash
# =============================================================================
# create-vm-numa-pmem.sh
# THIS SCRIPT ADDS PMEM AS A PMEM DEVICE!!! NOT A NUMA NODE
#
#
# Creates a KVM VM where PMEM is exposed as a memory-only NUMA node (node 1),
# mirroring the host topology (node 0 = DRAM + CPUs, node 1 = PMEM only).
#
#   Guest node 0: DRAM + all vCPUs
#   Guest node 1: PMEM (NVDIMM), no CPUs — memory-only node
#
# Host: Ubuntu 22.04/24.04
# Guest: Fedora 41
# QEMU user: libvirt-qemu
#
# PMEM namespace must be in devdax mode and NOT onlined as system-ram.
# Verify with: daxctl list -D
# If in system-ram mode, a separate devdax namespace must be created:
#   sudo ndctl create-namespace --mode=devdax --size=<size> --map=dev
#
# Usage:
#   ./create-vm-numa-pmem.sh -n <VM_NAME> -r <DRAM_MiB> -p <PMEM_MiB> \
#                            -c <VCPUS> -d <DEV_DAX_PATH>
#
# Get PMEM_MiB with:
#   ndctl list -N | python3 -c \
#     "import sys,json; [print(n['size']//1024//1024,'MiB') for n in json.load(sys.stdin)]"
#
# Example:
#   ./create-vm-numa-pmem.sh -n numa-vm -r 8192 -p 28224 -c 4 -d /dev/dax0.1
# =============================================================================
set -e

usage() {
    echo "Usage: $0 -n <VM_NAME> -r <DRAM_MiB> -p <PMEM_MiB> -c <VCPUS> -d <DEV_DAX_PATH>"
    echo ""
    echo "  -n  VM name"
    echo "  -r  DRAM size in MiB  (guest NUMA node 0)"
    echo "  -p  PMEM size in MiB  (guest NUMA node 1, must match devdax namespace size)"
    echo "  -c  vCPU count        (all assigned to node 0)"
    echo "  -d  Host devdax path  (e.g. /dev/dax0.1)"
    echo ""
    echo "Example: $0 -n numa-vm -r 8192 -p 28224 -c 4 -d /dev/dax0.1"
    exit 1
}

PMEM_PATH="/dev/dax0.1"

while getopts ":n:r:p:c:d:" opt; do
  case $opt in
    n) VM_NAME="$OPTARG" ;;
    r) RAM_MB="$OPTARG" ;;
    p) PMEM_MB="$OPTARG" ;;
    c) VCPUS="$OPTARG" ;;
    d) PMEM_PATH="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$VM_NAME" || -z "$RAM_MB" || -z "$PMEM_MB" || -z "$VCPUS" ]] && usage

DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
DISK_SIZE=30G
TMP_XML="/tmp/${VM_NAME}.xml"
VCPU_LAST=$(( VCPUS - 1 ))

# Get the device name (e.g., dax0.0)
DAX_NAME=$(basename "$PMEM_PATH")

# [1] Try daxctl first (most reliable)
ACTUAL_DAX_SIZE=$(daxctl list -d "$DAX_NAME" | python3 -c "import sys, json; print(json.load(sys.stdin)[0]['size'])" 2>/dev/null)

ACTUAL_DAX_MIB=$(( ACTUAL_DAX_SIZE / 1024 / 1024 ))

# Override user-supplied PMEM_MB with real device size
PMEM_MB=$ACTUAL_DAX_MIB
PMEM_SIZE_BYTES=$ACTUAL_DAX_SIZE   # exact bytes, no rounding

# Now derive all sizing from corrected values
# maxMemory formula:
# libvirt counts both the NUMA cell memory AND the NVDIMM device size against
# maxMemory, so PMEM is effectively counted twice. Formula:
#   DRAM + PMEM (numa cell) + PMEM (nvdimm device) + 8GiB headroom
MAX_MEM_KIB=$(( (RAM_MB + PMEM_MB + PMEM_MB + 8192) * 1024 ))
NUMA_TOTAL_KIB=$(( (RAM_MB + PMEM_MB) * 1024 ))
RAM_KIB=$(( RAM_MB * 1024 ))
PMEM_KIB=$(( PMEM_MB * 1024 ))

MAX_MEM_MIB_FINAL=$(( RAM_MB + ACTUAL_DAX_MIB + 2048 ))

echo "Detected Exact DAX Size: $ACTUAL_DAX_SIZE bytes ($ACTUAL_DAX_MIB MiB)"


echo "========================================="
echo "VM Type:  NUMA — PMEM as memory-only node"
echo "VM Name:  $VM_NAME"
echo "DRAM:     ${RAM_MB} MiB  → guest NUMA node 0"
echo "PMEM:     ${PMEM_MB} MiB  → guest NUMA node 1 (backed by $PMEM_PATH)"
echo "MaxMem:   $(( MAX_MEM_KIB / 1024 )) MiB"
echo "vCPUs:    $VCPUS  (CPUs 0-${VCPU_LAST} on node 0)"
echo "Disk:     $DISK_PATH ($DISK_SIZE)"
echo "========================================="
echo ""

read -p "Continue? (y/n): " choice
[[ "$choice" != "y" && "$choice" != "Y" ]] && exit 1

# =============================================================================
# STEP 1 — Validate devdax device
# =============================================================================
echo "[1] Validating $PMEM_PATH..."

if [[ ! -c "$PMEM_PATH" ]]; then
    echo "ERROR: $PMEM_PATH is not a character device or does not exist."
    echo ""
    echo "  If your PMEM is in system-ram mode, create a separate devdax namespace:"
    echo "    sudo ndctl create-namespace --mode=devdax --size=<size> --map=dev"
    echo "  Then check: ls /dev/dax*"
    exit 1
fi

# Check it's actually in devdax mode, not system-ram
DAX_NAME=$(basename "$PMEM_PATH")
DAX_MODE=$(daxctl list -D 2>/dev/null | python3 -c "
import sys, json
try:
    devs = json.load(sys.stdin)
    for d in devs:
        if d.get('chardev') == '${DAX_NAME}':
            print(d.get('mode', 'unknown'))
            break
except:
    pass
" 2>/dev/null || echo "unknown")

if [[ "$DAX_MODE" == "system-ram" ]]; then
    echo "ERROR: $PMEM_PATH is in system-ram mode — QEMU cannot open it."
    echo ""
    echo "  Options:"
    echo "  1. Use a different namespace that is in devdax mode"
    echo "  2. Create a new devdax namespace from available space:"
    echo "       sudo ndctl create-namespace --mode=devdax --size=<size> --map=dev"
    exit 1
fi

echo "  Device mode: $DAX_MODE ✓"

# =============================================================================
# STEP 2 — Permissions
# =============================================================================
echo "[2] Setting ACL for libvirt-qemu on $PMEM_PATH..."
sudo setfacl -m u:libvirt-qemu:rw "$PMEM_PATH"
#sudo setfacl u:qemu-system-x86_64:rw "$PMEM_PATH"
sudo setfacl -m g:kvm:rw "$PMEM_PATH"

getfacl "$PMEM_PATH" 2>/dev/null | grep libvirt-qemu || echo "  WARNING: ACL not verified"

# =============================================================================
# STEP 3 — Disk image
# =============================================================================
if [[ ! -f "$DISK_PATH" ]]; then
    echo "[3] Creating disk image..."
    sudo qemu-img create -f qcow2 "$DISK_PATH" $DISK_SIZE
else
    echo "[3] Disk image already exists, skipping."
fi

# =============================================================================
# STEP 4 — Install VM
# =============================================================================
if sudo virsh domstate "$VM_NAME" &>/dev/null; then
    echo "[4] VM '$VM_NAME' already exists — skipping install."
else
    echo "[4] Installing VM..."
    echo "    Complete installation, shut down from inside guest, then press ENTER."
    sudo virt-install \
      --name "$VM_NAME" \
      --os-variant fedora41 \
      --vcpus "$VCPUS" \
      --memory "$RAM_MB" \
      --cpu host-passthrough \
      --machine q35 \
      --location 'https://download.fedoraproject.org/pub/fedora/linux/releases/41/Server/x86_64/os/' \
      --disk path="$DISK_PATH",format=qcow2 \
      --network bridge=virbr0 \
      --graphics none \
      --console pty,target_type=serial \
      --extra-args='console=ttyS0,115200n8 serial' \
      --qemu-commandline="-machine q35,nvdimm=on -m slots=5,maxmem=${MAX_MEM_KIB}k -object memory-backend-file,id=mem1,share=on,mem-path=${PMEM_PATH},size=${PMEM_SIZE_BYTES},align=2M -device nvdimm,id=nv1,memdev=mem1,label-size=2M" \
      --wait -1
fi


#
#  -object memory-backend-file,id=mem1,share=on,mem-path=/dev/dax0.1,size=236755877888,align=2M \
#  -device nvdimm,id=nv1,memdev=mem1,pmem-force-system-ram=on

echo ""
read -p "Confirm VM is shut down, then press ENTER to continue..."

echo "  sudo ndctl list -RN"
echo ""
echo "  # Allocate from PMEM explicitly"
echo "  numactl --membind=1 --cpunodebind=0 <your_application>"
echo ""
echo "  # Online PMEM as RAM (makes it show in free -h)"
echo "  sudo daxctl reconfigure-device --mode=system-ram dax1.0"
echo "========================================="