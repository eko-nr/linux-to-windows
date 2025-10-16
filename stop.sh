VM_NAME=${VM_NAME:-win10ltsc}

sudo virsh shutdown $VM_NAME
echo "VM stopped"