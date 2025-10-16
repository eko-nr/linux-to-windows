VM_NAME=${VM_NAME:-win10ltsc}

sudo virsh stop $VM_NAME
echo "VM stopped"