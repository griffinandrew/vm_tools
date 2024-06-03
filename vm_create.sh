#!/bin/bash


#sudo virt-install --name ubuntu-guest --os-variant ubuntu20.04 --vcpus 2 --ram 2048 --location http://ftp.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/ --network bridge=virbr0,model=virtio --graphics none --extra-args='console=ttyS0,115200n8 serial'
#
#
#
usage() {
    echo "Usage: $0 -n <VM name> -r <RAM in MB> -c <Number of vCPUs>"
    exit 1
}

#get command line options
while getopts ":n:r:c:" opt; do
    case $opt in
        n)
            VM_NAME="$OPTARG"
            ;;
        r)
            RAM="$OPTARG"
            ;;
        c)
            VCPUS="$OPTARG"
            ;;
        *)
            usage
            ;;
    esac
done

#ensure provided
if [[ -z $VM_NAME ]] || [[ -z $RAM ]] || [[ -z $VCPUS ]]; then
    usage
fi

#install vm 
#VIRT_INSTALL_COMMAND="sudo virt-install \
#--name $VM_NAME \
#--os-variant ubuntu20.04 \
#--vcpus $VCPUS \
#--memory $RAM \
#--location http://ftp.ubuntu.com/ubuntu/dists/focal/main/installer-amd64/ \
#--network bridge=virbr0,model=virtio \
#--graphics none
#--extra-args='console=ttyS0,115200n8 serial'"

DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"

#size in gb?
DISK_SIZE=20 

VIRT_INSTALL_COMMAND="sudo virt-install \
--name $VM_NAME \
--os-variant fedora38 \
--vcpus $VCPUS \
--memory $RAM \
--location https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/38/Server/x86_64/os/ \
--disk path=$DISK_PATH,size=$DISK_SIZE \
--network bridge=virbr0,model=virtio \
--graphics none \
--console pty,target_type=serial \
--extra-args='console=ttyS0,115200n8 serial' "

echo "Executing the following command:"
echo "$VIRT_INSTALL_COMMAND"

read -p "Do you want to continue? (y/n): " choice
case "$choice" in
  y|Y ) ;;
  * ) echo "Aborted."; exit 1;;
esac

# exec virt-install
eval $VIRT_INSTALL_COMMAND

echo "VM $VM_NAME creation complete."
