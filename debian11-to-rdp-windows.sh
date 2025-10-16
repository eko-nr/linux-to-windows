#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== VM Windows 10 Tiny Installation Script for Debian 11 ===${NC}\n"

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
read -p "VM name (default: win10tiny): " VM_NAME
VM_NAME=${VM_NAME:-win10tiny}

read -p "RAM in MB (default: 2048): " RAM_SIZE
RAM_SIZE=${RAM_SIZE:-2048}

read -p "Number of vCPUs (default: 2): " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-2}

read -p "Disk size in GB (default: 40): " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-40}

read -p "VNC port (default: 5901): " VNC_PORT
VNC_PORT=${VNC_PORT:-5901}

# Display configuration summary
echo -e "\n${GREEN}=== Configuration Summary ===${NC}"
echo "OS Version     : Debian $VERSION_ID ($VERSION_CODENAME)"
echo "Swap Size      : ${SWAP_SIZE}G"
echo "VM Name        : ${VM_NAME}"
echo "RAM            : ${RAM_SIZE}MB"
echo "vCPU           : ${VCPU_COUNT}"
echo "Disk Size      : ${DISK_SIZE}G"
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
sudo virsh net-start default 2>/dev/null || echo "Default network already active"
sudo virsh net-autostart default

# Check KVM
echo -e "${YELLOW}[3/9] Checking KVM modules...${NC}"
lsmod | grep kvm

# Download ISO
echo -e "${YELLOW}[4/9] Downloading Windows 10 Tiny ISO...${NC}"
sudo mkdir -p /var/lib/libvirt/boot
cd /var/lib/libvirt/boot
if [ ! -f "Windows10-Tiny.iso" ]; then
    sudo wget -O Windows10-Tiny.iso "https://archive.org/download/windows-10-tiny-b-4-x-64/Windows%2010%20%28Tiny%29.iso"
else
    echo "ISO already exists, skipping download."
fi

ls -lh Windows10-Tiny.iso
file Windows10-Tiny.iso

# Create disk image
echo -e "${YELLOW}[5/9] Creating ${DISK_SIZE}G disk image...${NC}"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# Setup swap
echo -e "${YELLOW}[6/9] Setting up ${SWAP_SIZE}G swap...${NC}"
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
echo -e "${YELLOW}[7/9] Cleaning up old VM (if exists)...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# Install VM
echo -e "${YELLOW}[8/9] Creating Virtual Machine...${NC}"
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom /var/lib/libvirt/boot/Windows10-Tiny.iso \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,size=${DISK_SIZE} \
  --os-variant win10 \
  --network network=default \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --noautoconsole

# Access info
echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo -e "${GREEN}VM created successfully!${NC}\n"
echo "Access VM via VNC:"
echo "  IP: $(hostname -I | awk '{print $1}')"
echo "  Port: ${VNC_PORT}"
echo ""
echo "Use VNC viewer to access VM, example:"
echo "  vncviewer $(hostname -I | awk '{print $1}'):${VNC_PORT}"
echo ""
echo "Or use virt-manager for GUI:"
echo "  virt-manager"
echo ""
echo "VM Management Commands:"
echo "  Start VM:   sudo virsh start ${VM_NAME}"
echo "  Stop VM:    sudo virsh shutdown ${VM_NAME}"
echo "  Force Stop: sudo virsh destroy ${VM_NAME}"
echo "  Delete VM:  sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo "  VM Status:  sudo virsh list --all"