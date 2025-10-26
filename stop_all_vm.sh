#!/bin/bash

# Stop all running virtual machines using virsh
echo "Stopping all running VMs..."

# Loop through all active VMs and destroy them
for vm in $(sudo virsh list --name); do
  echo "→ Stopping VM: $vm"
  sudo virsh destroy "$vm"
done

# Reset hugepages
echo 0 | sudo tee /proc/sys/vm/nr_hugepages > /dev/null

echo "All VMs have been stopped, and hugepages reset to 0."