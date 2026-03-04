#!/bin/bash

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <original_vm_name> <clone_vm_name> <new_disk_size>"
    echo "Example: $0 numa-vm numa-vm-clone 60G"
    exit 1
fi

ORIGINAL="$1"
CLONE="$2"
NEW_SIZE="$3"

CLONE_DISK="/var/lib/libvirt/images/${CLONE}.qcow2"

echo "[1] Shutting down $ORIGINAL..."
virsh shutdown "$ORIGINAL"

# Wait for it to actually shut off
echo "    Waiting for shutdown..."
while [ "$(virsh domstate $ORIGINAL)" != "shut off" ]; do
    sleep 2
done
echo "    Shut off."

echo "[2] Cloning $ORIGINAL → $CLONE..."
sudo virt-clone --original "$ORIGINAL" --name "$CLONE" --auto-clone

echo "[3] Resizing disk to $NEW_SIZE..."
sudo qemu-img resize "$CLONE_DISK" "$NEW_SIZE"

echo "[4] Starting $CLONE..."
sudo virsh start "$CLONE"

echo "[5] Starting $ORIGINAL..."
sudo virsh start "$ORIGINAL"

echo ""
echo "Done. Both VMs running:"
virsh list --all

echo ""
echo "Inside $CLONE, expand the filesystem:"
echo "  sudo dnf install -y cloud-utils-growpart"
echo "  sudo growpart /dev/vda 2"
echo "  sudo pvresize /dev/vda2"
echo "  sudo lvextend -l +100%FREE /dev/mapper/fedora_fedora-root"
echo "  sudo xfs_growfs /"
