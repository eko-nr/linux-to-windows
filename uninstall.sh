#!/bin/bash

# ============================================================
# Uninstaller for Windows 10 LTSC VM (KVM)
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

VM_NAME=${1:-win10ltsc}

echo -e "${YELLOW}=== Uninstalling VM: ${VM_NAME} ===${NC}"

# Stop VM if running
if sudo virsh list | grep -q "${VM_NAME}"; then
    echo -e "${YELLOW}→ Shutting down VM...${NC}"
    sudo virsh destroy ${VM_NAME} 2>/dev/null
fi

# Undefine and remove storage
echo -e "${YELLOW}→ Removing VM definition and disks...${NC}"
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true
sudo rm -f /var/lib/libvirt/images/${VM_NAME}.img 2>/dev/null

# Ask to remove cached ISO
ISO_FILE="/opt/vm-isos/Windows10-Ltsc.iso"
read -p "Remove cached ISO (${ISO_FILE})? (y/n): " DEL_ISO
if [[ $DEL_ISO =~ ^[Yy]$ ]]; then
    sudo rm -f "$ISO_FILE"
    echo -e "${GREEN}✓ ISO removed${NC}"
else
    echo -e "${YELLOW}→ ISO kept at ${ISO_FILE}${NC}"
fi

# Optionally disable swap
if grep -q "/swapfile" /etc/fstab; then
    read -p "Remove swapfile /swapfile? (y/n): " DEL_SWAP
    if [[ $DEL_SWAP =~ ^[Yy]$ ]]; then
        sudo swapoff /swapfile 2>/dev/null
        sudo rm -f /swapfile
        sudo sed -i '/swapfile/d' /etc/fstab
        echo -e "${GREEN}✓ Swap removed${NC}"
    fi
fi

echo -e "${GREEN}✅ VM ${VM_NAME} fully uninstalled${NC}"
