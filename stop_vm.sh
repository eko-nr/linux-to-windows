VM_NAME=${VM_NAME:-win10ltsc}

sudo virsh destroy $VM_NAME
echo "VM stopped"