VM_NAME=${VM_NAME:-win10ltsc}

sudo virsh destroy $VM_NAME
echo 0 | sudo tee /proc/sys/vm/nr_hugepages

echo "VM stopped"