#!/bin/bash

echo "Starting all running VMs..."

# Loop through all active VMs and destroy them
for vm in $(sudo virsh list --name); do
  echo "→ Starting VM: $vm"
  sudo virsh start "$vm"
done

echo "All VMs have been started"
