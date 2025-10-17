#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== VM Windows 10 LTSC Installation Script for Debian 11 ===${NC}\n"

# Function for cleanup and exit
cleanup_and_exit() {
    echo -e "\n${RED}❌ Cleaning up processes and exiting...${NC}"
    # Kill all related processes if any
    pkill -9 -f qemu 2>/dev/null
    pkill -9 -f libvirt 2>/dev/null
    pkill -9 -f virt 2>/dev/null
    exit 1
}

# Check if running on Debian 11
echo -e "${BLUE}[CHECK] Verifying Debian 11...${NC}\n"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        echo -e "${RED}✗ This script is designed for Debian only!${NC}"
        echo -e "${RED}  Detected OS: $ID${NC}"
        cleanup_and_exit
    fi
    
    if [[ "$VERSION_ID" != "11" ]]; then
        echo -e "${YELLOW}⚠ Warning: This script is optimized for Debian 11${NC}"
        echo -e "${YELLOW}  Detected version: Debian $VERSION_ID${NC}"
        read -p "Continue anyway? (y/n): " CONTINUE
        if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
            cleanup_and_exit
        fi
    else
        echo -e "${GREEN}✓ Debian 11 (Bullseye) detected${NC}"
    fi
else
    echo -e "${YELLOW}⚠ Cannot detect OS version, continuing...${NC}"
fi

# KVM Support Validation
echo -e "\n${BLUE}[VALIDATION] Checking KVM support...${NC}\n"

# Check 1: CPU virtualization support
echo -e "${YELLOW}→ Checking CPU virtualization...${NC}"
if grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    echo -e "${GREEN}✓ CPU supports virtualization (vmx/svm)${NC}"
else
    echo -e "${RED}✗ CPU does not support virtualization!${NC}"
    echo -e "${RED}  This VPS does not support hardware virtualization.${NC}"
    cleanup_and_exit
fi

# Check 2: Nested virtualization / KVM device
echo -e "${YELLOW}→ Checking KVM device...${NC}"
if [ -e /dev/kvm ]; then
    echo -e "${GREEN}✓ /dev/kvm is available${NC}"
    
    # Check permissions
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo -e "${GREEN}✓ /dev/kvm permissions OK${NC}"
    else
        echo -e "${YELLOW}⚠ Adjusting /dev/kvm permissions${NC}"
        sudo chmod 666 /dev/kvm 2>/dev/null
    fi
else
    echo -e "${RED}✗ /dev/kvm not found!${NC}"
    echo -e "${RED}  This VPS likely:${NC}"
    echo -e "${RED}  - Does not have nested virtualization enabled${NC}"
    echo -e "${RED}  - Is using containers (LXC/Docker) instead of VM${NC}"
    echo -e "${RED}  - Does not support KVM${NC}"
    cleanup_and_exit
fi

# Check 3: KVM module loaded
echo -e "${YELLOW}→ Checking KVM module...${NC}"
if lsmod | grep -q kvm; then
    echo -e "${GREEN}✓ KVM module already loaded${NC}"
    lsmod | grep kvm | while read line; do
        echo -e "  ${GREEN}→${NC} $line"
    done
else
    echo -e "${YELLOW}⚠ KVM module not loaded, attempting to load...${NC}"
    
    # Try to load module
    if grep -q vmx /proc/cpuinfo; then
        sudo modprobe kvm_intel 2>/dev/null
    elif grep -q svm /proc/cpuinfo; then
        sudo modprobe kvm_amd 2>/dev/null
    fi
    
    # Check again
    if lsmod | grep -q kvm; then
        echo -e "${GREEN}✓ KVM module loaded successfully${NC}"
    else
        echo -e "${RED}✗ Failed to load KVM module!${NC}"
        echo -e "${RED}  Kernel may not support KVM or nested virtualization is disabled.${NC}"
        cleanup_and_exit
    fi
fi

# Check 4: Virtualization type
echo -e "${YELLOW}→ Checking virtualization type...${NC}"
if command -v systemd-detect-virt &> /dev/null; then
    VIRT_TYPE=$(systemd-detect-virt)
    echo -e "${BLUE}  Type: $VIRT_TYPE${NC}"
    
    case $VIRT_TYPE in
        kvm|qemu)
            echo -e "${GREEN}✓ Running on KVM/QEMU - nested virtualization may be available${NC}"
            ;;
        none)
            echo -e "${GREEN}✓ Running on bare metal${NC}"
            ;;
        openvz|lxc|docker|container)
            echo -e "${RED}✗ Running in container ($VIRT_TYPE)!${NC}"
            echo -e "${RED}  Containers do not support KVM. You need a KVM-based VPS.${NC}"
            cleanup_and_exit
            ;;
        *)
            echo -e "${YELLOW}⚠ Virtualization type: $VIRT_TYPE${NC}"
            echo -e "${YELLOW}  Proceeding with caution...${NC}"
            ;;
    esac
fi

# Check 5: Test kvm-ok (if available)
if command -v kvm-ok &> /dev/null; then
    echo -e "${YELLOW}→ Running kvm-ok test...${NC}"
    if kvm-ok 2>&1 | grep -q "KVM acceleration can be used"; then
        echo -e "${GREEN}✓ KVM acceleration verified${NC}"
    else
        echo -e "${RED}✗ KVM acceleration test failed!${NC}"
        kvm-ok
        cleanup_and_exit
    fi
fi

echo -e "\n${GREEN}✅ VALIDATION PASSED - This VPS supports KVM!${NC}\n"
sleep 2

# Configuration input
echo -e "${YELLOW}Swap Configuration:${NC}"
read -p "Swap size in GB (default: 4): " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}

echo -e "\n${YELLOW}Virtual Machine Configuration:${NC}"
read -p "VM name (default: win10ltsc): " VM_NAME
VM_NAME=${VM_NAME:-win10ltsc}

read -p "RAM in MB (default: 2048): " RAM_SIZE
RAM_SIZE=${RAM_SIZE:-2048}

read -p "Number of vCPUs (default: 2): " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-2}

read -p "Disk size in GB (default: 40): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-40}

read -p "VNC port (default: 5901): " VNC_PORT
VNC_PORT=${VNC_PORT:-5901}

echo -e "\n${YELLOW}Storage Driver Configuration:${NC}"
echo "1. IDE - Compatible, works immediately (recommended for easy setup)"
echo "2. VirtIO - Better performance, requires driver loading during install"
read -p "Choose storage driver (1 or 2, default: 1): " STORAGE_CHOICE
STORAGE_CHOICE=${STORAGE_CHOICE:-1}

if [ "$STORAGE_CHOICE" = "1" ]; then
    DISK_BUS="ide"
    NETWORK_MODEL="e1000"
    STORAGE_TYPE="IDE (Compatible)"
else
    DISK_BUS="virtio"
    NETWORK_MODEL="virtio"
    STORAGE_TYPE="VirtIO (High Performance)"
fi

# Display configuration summary
echo -e "\n${GREEN}=== Configuration Summary ===${NC}"
echo "OS Version     : Debian $VERSION_ID ($VERSION_CODENAME)"
echo "Swap Size      : ${SWAP_SIZE}G"
echo "VM Name        : ${VM_NAME}"
echo "RAM            : ${RAM_SIZE}MB"
echo "vCPU           : ${VCPU_COUNT}"
echo "Disk Size      : ${DISK_SIZE}G"
echo "Storage Type   : ${STORAGE_TYPE}"
echo "VNC Port       : ${VNC_PORT}"
echo ""
read -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Starting installation...${NC}\n"

# Update and install packages for Debian 11
echo -e "${YELLOW}[1/9] Updating system and installing packages...${NC}"
sudo apt update && sudo apt install -y \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    virt-manager \
    cpu-checker \
    wget

# Verify KVM installation
echo -e "${YELLOW}[1.5/9] Verifying KVM installation...${NC}"
if ! command -v qemu-system-x86_64 &> /dev/null; then
    echo -e "${RED}✗ QEMU installation failed!${NC}"
    cleanup_and_exit
fi

if ! systemctl is-active --quiet libvirtd 2>/dev/null; then
    echo -e "${YELLOW}⚠ libvirtd not active, attempting to start...${NC}"
    sudo systemctl start libvirtd
    if ! systemctl is-active --quiet libvirtd; then
        echo -e "${RED}✗ Failed to start libvirtd!${NC}"
        cleanup_and_exit
    fi
fi

echo -e "${GREEN}✓ KVM packages installed successfully${NC}"

# Enable libvirtd
echo -e "${YELLOW}[2/9] Enabling and starting libvirtd...${NC}"
sudo systemctl enable --now libvirtd

# Configure default network with NAT
echo -e "${YELLOW}[2.5/9] Configuring network...${NC}"

# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

# Stop and undefine existing network
sudo virsh net-destroy default 2>/dev/null || true
sudo virsh net-undefine default 2>/dev/null || true

# Create network configuration
cat > /tmp/default-network.xml << 'EOF'
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.2' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF

# Define and start network
sudo virsh net-define /tmp/default-network.xml
sudo virsh net-start default
sudo virsh net-autostart default

echo -e "${GREEN}✓ Network configured with NAT${NC}"
sudo virsh net-list --all

# Check KVM
echo -e "${YELLOW}[3/9] Checking KVM modules...${NC}"
lsmod | grep kvm

# Download Windows ISO
echo -e "${YELLOW}[4/9] Downloading Windows 10 LTSC 2021 ISO...${NC}"
sudo mkdir -p /var/lib/libvirt/boot
cd /var/lib/libvirt/boot
if [ ! -f "Windows10-LTSC.iso" ]; then
    echo "Downloading Windows 10 LTSC 64-bit (this may take a while)..."
    sudo wget -O Windows10-LTSC.iso "https://archive.org/download/windows-10-ltsc-2021/windows%2010%20LTSC%2064.iso"
    
    # Verify download
    if [ $? -eq 0 ] && [ -f "Windows10-LTSC.iso" ]; then
        echo -e "${GREEN}✓ Download completed successfully${NC}"
    else
        echo -e "${RED}✗ Download failed!${NC}"
        cleanup_and_exit
    fi
else
    echo "Windows ISO already exists, skipping download."
fi

ls -lh Windows10-LTSC.iso
file Windows10-LTSC.iso

# Download VirtIO drivers ISO (always download for option to use later)
echo -e "${YELLOW}[5/9] Downloading VirtIO drivers ISO...${NC}"
if [ ! -f "virtio-win.iso" ]; then
    echo "Downloading VirtIO drivers..."
    sudo wget -O virtio-win.iso https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
    
    if [ $? -eq 0 ] && [ -f "virtio-win.iso" ]; then
        echo -e "${GREEN}✓ VirtIO drivers downloaded successfully${NC}"
    else
        echo -e "${YELLOW}⚠ VirtIO download failed, trying alternative...${NC}"
        sudo wget -O virtio-win.iso https://github.com/virtio-win/virtio-win-pkg-scripts/blob/master/virtio-win.iso?raw=true
    fi
else
    echo "VirtIO ISO already exists, skipping download."
fi

if [ -f "virtio-win.iso" ]; then
    ls -lh virtio-win.iso
fi

# Create disk image
echo -e "${YELLOW}[6/9] Creating ${DISK_SIZE}G disk image...${NC}"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# Setup swap
echo -e "${YELLOW}[7/9] Setting up ${SWAP_SIZE}G swap...${NC}"
if [ ! -f /swapfile ]; then
    sudo fallocate -l ${SWAP_SIZE}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    # Check if already in fstab
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    echo "Swap created and activated successfully."
else
    echo "Swapfile already exists."
    sudo swapon /swapfile 2>/dev/null || echo "Swap already active."
fi

# Remove old VM if exists
echo -e "${YELLOW}[8/9] Cleaning up old VM (if exists)...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# Install VM
echo -e "${YELLOW}[9/9] Creating Virtual Machine...${NC}"

# Build virt-install command based on storage choice
VIRT_INSTALL_CMD="sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom /var/lib/libvirt/boot/Windows10-LTSC.iso \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,bus=${DISK_BUS} \
  --os-variant win10 \
  --network network=default,model=${NETWORK_MODEL} \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --noautoconsole"

# Add VirtIO drivers CD if available
if [ -f "/var/lib/libvirt/boot/virtio-win.iso" ]; then
    VIRT_INSTALL_CMD="${VIRT_INSTALL_CMD} --disk /var/lib/libvirt/boot/virtio-win.iso,device=cdrom"
    echo -e "${GREEN}✓ VirtIO drivers ISO will be attached as second CD${NC}"
fi

# Execute the command
eval $VIRT_INSTALL_CMD

sleep 5

# Get VM IP
echo -e "${YELLOW}Getting VM IP address...${NC}"
VM_IP=$(sudo virsh domifaddr ${VM_NAME} 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)

# Access info
VPS_IP=$(hostname -I | awk '{print $1}')

echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo -e "${GREEN}VM created successfully!${NC}\n"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VNC Connection:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  IP:   ${VPS_IP}"
echo "  Port: ${VNC_PORT}"
echo ""
echo "Use VNC viewer to access VM:"
echo "  vncviewer ${VPS_IP}:${VNC_PORT}"
echo ""

if [ "$STORAGE_CHOICE" = "2" ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "VirtIO Driver Installation (Required!):"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}You chose VirtIO drivers for better performance.${NC}"
    echo "During Windows Setup when it asks to select drive:"
    echo ""
    echo "1. Click 'Load driver'"
    echo "2. Click 'Browse'"
    echo "3. Navigate to the VirtIO CD (usually D: or E:)"
    echo "4. Go to: viostor\\w10\\amd64"
    echo "5. Select 'Red Hat VirtIO SCSI controller'"
    echo "6. Click OK"
    echo "7. The disk should now appear for installation"
    echo ""
    echo "For network drivers after Windows installation:"
    echo "  Navigate to: NetKVM\\w10\\amd64"
    echo ""
else
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Storage Configuration:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${GREEN}Using IDE storage - Windows will detect disk automatically!${NC}"
    echo ""
    echo "Optional: After installation, you can convert to VirtIO for better performance"
    echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RDP Connection (After Windows Installation):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -n "$VM_IP" ]; then
    echo "  VM IP: ${VM_IP}"
    echo "  Port:  3389 (default RDP port)"
    echo ""
    echo "Connect using:"
    echo "  mstsc /v:${VM_IP}:3389"
else
    echo "  VM IP not detected yet. Get it with:"
    echo "    sudo virsh domifaddr ${VM_NAME}"
    echo ""
    echo "  Then connect to VM_IP:3389"
fi
echo ""
echo -e "${YELLOW}IMPORTANT: Enable RDP in Windows first!${NC}"
echo "1. Complete Windows installation via VNC"
echo "2. Open System Properties (Win + Pause)"
echo "3. Click 'Remote settings'"
echo "4. Enable 'Allow remote connections to this computer'"
echo "5. Configure Windows Firewall:"
echo "   Run in PowerShell as Admin:"
echo "   Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'"
echo ""
echo -e "${GREEN}Note: Since all ports are open on your VPS, you can${NC}"
echo -e "${GREEN}connect directly to the VM's IP address on port 3389.${NC}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VM Management Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Start VM:   sudo virsh start ${VM_NAME}"
echo "  Stop VM:    sudo virsh shutdown ${VM_NAME}"
echo "  Force Stop: sudo virsh destroy ${VM_NAME}"
echo "  Delete VM:  sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo "  VM Status:  sudo virsh list --all"
echo "  Get VM IP:  sudo virsh domifaddr ${VM_NAME}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Check Logs Commands:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  VM Logs:      sudo tail -f /var/log/libvirt/qemu/${VM_NAME}.log"
echo "  Libvirt Logs: sudo tail -f /var/log/libvirt/libvirtd.log"
echo "  System Logs:  sudo journalctl -u libvirtd -f"
echo "  VM Console:   sudo virsh console ${VM_NAME}"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Network Troubleshooting (if no internet):"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Check network:     sudo virsh net-list --all"
echo "  Restart network:   sudo virsh net-destroy default && sudo virsh net-start default"
echo "  Check IP forward:  cat /proc/sys/net/ipv4/ip_forward (should be 1)"
echo "  Check DNS in VM:   Use 8.8.8.8 or 1.1.1.1 as DNS"
echo ""
echo "  Inside Windows VM, check network settings:"
echo "  - Network adapter should get IP via DHCP (192.168.122.x)"
echo "  - Gateway should be 192.168.122.1"
echo "  - DNS: 8.8.8.8 or 1.1.1.1"
echo ""

echo -e "${GREEN}Installation script completed successfully!${NC}"
echo -e "${GREEN}All firewall/iptables configurations removed as requested.${NC}"