#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}=== Windows 10 LTSC VM Reinstallation Script ===${NC}"

read -p "Enter existing VM name to reinstall (default: win10ltsc): " VM_NAME
VM_NAME=${VM_NAME:-win10ltsc}

# Confirm deletion
echo -e "${YELLOW}⚠ This will delete and reinstall the VM '${VM_NAME}' including all data.${NC}"
read -p "Are you sure? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

# Stop and remove old VM
echo -e "${YELLOW}[1/5] Removing old VM and disk...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || echo "No running VM to stop."
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true
sudo rm -f /var/lib/libvirt/images/${VM_NAME}.img 2>/dev/null

# Ask for new config
echo -e "\n${GREEN}=== New VM Configuration ===${NC}"
read -p "RAM in MB (default: 2048): " RAM_SIZE
RAM_SIZE=${RAM_SIZE:-2048}

read -p "vCPU count (default: 2): " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-2}

read -p "Disk size in GB (default: 40): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-40}

read -p "VNC port (default: 5901): " VNC_PORT
VNC_PORT=${VNC_PORT:-5901}

ISO_PATH="/var/lib/libvirt/boot/Windows10-LTSC.iso"

if [ ! -f "$ISO_PATH" ]; then
    echo -e "${RED}Windows 10 ISO not found at $ISO_PATH${NC}"
    echo "Please run your original install script first to download it."
    exit 1
fi

# Create new disk
echo -e "${YELLOW}[2/5] Creating new ${DISK_SIZE}G disk image...${NC}"
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# Recreate VM
echo -e "${YELLOW}[3/5] Recreating virtual machine...${NC}"
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom ${ISO_PATH} \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,size=${DISK_SIZE} \
  --os-variant win10 \
  --network network=default \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --noautoconsole

# Autostart
sudo virsh net-autostart default 2>/dev/null

# Done
echo -e "\n${GREEN}=== Reinstallation Complete ===${NC}"
echo "Access via VNC:"
echo "  IP: $(hostname -I | awk '{print $1}')"
echo "  Port: ${VNC_PORT}"
echo ""
echo "VM Management Commands:"
echo "  Start VM:   sudo virsh start ${VM_NAME}"
echo "  Stop VM:    sudo virsh shutdown ${VM_NAME}"
echo "  Delete VM:  sudo virsh undefine ${VM_NAME} --remove-all-storage"