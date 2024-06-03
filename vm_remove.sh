#!/bin/bash

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <vm_name>"
    exit 1
fi

vm_name="$1"

if ! virsh list --all | grep -q "\<$vm_name\>"; then
    echo "Error: VM '$vm_name' does not exist."
    exit 1
fi

virsh shutdown "$vm_name"

while virsh list --all | grep -q "\<$vm_name\>"; do
    echo "Waiting for VM '$vm_name' to shut down..."
    sleep 5
done

virsh undefine "$vm_name"

echo "VM '$vm_name' has been successfully shutdown and undefined."
