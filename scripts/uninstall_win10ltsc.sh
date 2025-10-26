#!/bin/bash

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
VM_NAME=${1:-win10ltsc}
ISO_FILE="/opt/vm-isos/Windows10-Ltsc.iso"

echo -e "${YELLOW}=== Uninstalling VM: ${VM_NAME} ===${NC}"

# Stop VM if running
if sudo virsh list | grep -q "$VM_NAME"; then
    echo -e "${YELLOW}→ Stopping VM...${NC}"
    sudo virsh destroy "$VM_NAME" 2>/dev/null || true
fi

# Remove definition
echo -e "${YELLOW}→ Removing VM definition & disk...${NC}"
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true
sudo rm -f "/var/lib/libvirt/images/${VM_NAME}.img" 2>/dev/null

# Ask to remove swap
if grep -q '/swapfile' /etc/fstab; then
    read -p "Remove /swapfile (created by installer)? (y/n): " SWP
    if [[ $SWP =~ ^[Yy]$ ]]; then
        sudo swapoff /swapfile 2>/dev/null || true
        sudo rm -f /swapfile
        sudo sed -i '/swapfile/d' /etc/fstab
        echo -e "${GREEN}✓ Swap removed${NC}"
    fi
fi

echo -e "${GREEN}✅ Uninstallation complete${NC}"
