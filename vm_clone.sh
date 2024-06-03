#!/bin/bash 

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <original_vm_name> <clone_vm_name>"
    exit 1
fi

original_vm_name="$1"
clone_vm_name="$2"

virsh shutdown "$original_vm_name"

sudo virt-clone --original "$original_vm_name" --name "$clone_vm_name" --auto-clone

virsh start "$clone_vm_name"
virsh start "$original_vm_name"

virsh list --all
