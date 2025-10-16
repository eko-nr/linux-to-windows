#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Fix Windows Driver Error - Add VirtIO Drivers ===${NC}\n"

# Get VM name
read -p "VM name (default: win10ltsc): " VM_NAME
VM_NAME=${VM_NAME:-win10ltsc}

echo -e "\n${YELLOW}[1/5] Stopping VM...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || echo "VM already stopped"

echo -e "${YELLOW}[2/5] Downloading VirtIO drivers ISO...${NC}"
cd /var/lib/libvirt/boot

if [ ! -f "virtio-win.iso" ]; then
    echo "Downloading VirtIO drivers (this may take a few minutes)..."
    sudo wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
    
    if [ $? -eq 0 ] && [ -f "virtio-win.iso" ]; then
        echo -e "${GREEN}✓ VirtIO drivers downloaded successfully${NC}"
    else
        echo -e "${RED}✗ Download failed! Trying alternative source...${NC}"
        sudo wget -O virtio-win.iso https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/virtio-win.iso?raw=true
    fi
else
    echo "VirtIO ISO already exists, skipping download."
fi

ls -lh virtio-win.iso

echo -e "${YELLOW}[3/5] Modifying VM configuration to use IDE disk (temporary)...${NC}"

# Get the current disk path
DISK_PATH=$(sudo virsh domblklist ${VM_NAME} --details | grep disk | awk '{print $4}')
if [ -z "$DISK_PATH" ]; then
    DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.img"
fi

echo "Current disk: $DISK_PATH"

# Undefine VM but keep storage
sudo virsh undefine ${VM_NAME}

echo -e "${YELLOW}[4/5] Recreating VM with IDE disk and VirtIO drivers CD...${NC}"

# Get VM specs
RAM_SIZE=${RAM_SIZE:-2048}
VCPU_COUNT=${VCPU_COUNT:-2}
VNC_PORT=${VNC_PORT:-5901}

# Recreate VM with IDE disk (for Windows installation)
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom /var/lib/libvirt/boot/Windows10-LTSC.iso \
  --disk path=${DISK_PATH},bus=ide \
  --disk /var/lib/libvirt/boot/virtio-win.iso,device=cdrom \
  --os-variant win10 \
  --network network=default,model=e1000 \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --noautoconsole

echo -e "${YELLOW}[5/5] VM recreated with IDE disk${NC}"

echo -e "\n${GREEN}=== Fix Applied Successfully! ===${NC}\n"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Next Steps:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Connect to VM via VNC again:"
echo "   vncviewer $(hostname -I | awk '{print $1}'):${VNC_PORT}"
echo ""
echo "2. Windows Setup should now detect the disk"
echo ""
echo "3. If you want to use VirtIO drivers (better performance):"
echo "   - Click 'Load driver'"
echo "   - Click 'Browse'"
echo "   - Navigate to the VirtIO CD (usually D: or E:)"
echo "   - Go to: viostor\\w10\\amd64"
echo "   - Select the Red Hat VirtIO SCSI controller"
echo "   - Click OK"
echo ""
echo "4. The disk should now appear in the installation list"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${BLUE}Note: We're using IDE bus temporarily for easier installation.${NC}"
echo -e "${BLUE}After Windows is installed, you can convert to VirtIO for better performance.${NC}"