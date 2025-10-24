#!/bin/bash
echo "Starting all defined VMs..."

for vm in $(sudo virsh list --all --name); do
  echo "→ Starting VM: $vm"
  sudo virsh start "$vm" && echo "   $vm started successfully"
done

echo "All VMs have been started."
