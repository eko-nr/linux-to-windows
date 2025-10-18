#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== VM Windows 10 LTSC Installation Script for Debian 13 ===${NC}\n"

# Function for cleanup and exit
cleanup_and_exit() {
    echo -e "\n${RED}❌ Cleaning up processes and exiting...${NC}"
    pkill -9 -f qemu 2>/dev/null
    pkill -9 -f libvirt 2>/dev/null
    pkill -9 -f virt 2>/dev/null
    exit 1
}

# Check if running on Debian
echo -e "${BLUE}[CHECK] Verifying Debian installation...${NC}\n"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        echo -e "${RED}✗ This script is designed for Debian only!${NC}"
        echo -e "${RED}  Detected OS: $ID${NC}"
        cleanup_and_exit
    fi
    
    if [[ "$VERSION_ID" != "13" ]]; then
        echo -e "${YELLOW}⚠ Warning: This script is optimized for Debian 13${NC}"
        echo -e "${YELLOW}  Detected version: Debian $VERSION_ID${NC}"
        read -p "Continue anyway? (y/n): " CONTINUE
        if [[ ! $CONTINUE =~ ^[Yy]$ ]]; then
            cleanup_and_exit
        fi
    else
        echo -e "${GREEN}✓ Debian 13 (Trixie) detected${NC}"
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
    
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
        echo -e "${GREEN}✓ /dev/kvm permissions OK${NC}"
    else
        echo -e "${YELLOW}⚠ Adjusting /dev/kvm permissions${NC}"
        sudo chmod 666 /dev/kvm 2>/dev/null
    fi
else
    echo -e "${RED}✗ /dev/kvm not found!${NC}"
    echo -e "${RED}  This VPS likely does not support KVM${NC}"
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
    
    if grep -q vmx /proc/cpuinfo; then
        sudo modprobe kvm_intel 2>/dev/null
    elif grep -q svm /proc/cpuinfo; then
        sudo modprobe kvm_amd 2>/dev/null
    fi
    
    if lsmod | grep -q kvm; then
        echo -e "${GREEN}✓ KVM module loaded successfully${NC}"
    else
        echo -e "${RED}✗ Failed to load KVM module!${NC}"
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

read -p "RDP forwarding port on host (default: 3389): " RDP_HOST_PORT
RDP_HOST_PORT=${RDP_HOST_PORT:-3389}

# Display configuration summary
echo -e "\n${GREEN}=== Configuration Summary ===${NC}"
echo "OS Version     : Debian $VERSION_ID ($VERSION_CODENAME)"
echo "Swap Size      : ${SWAP_SIZE}G"
echo "VM Name        : ${VM_NAME}"
echo "RAM            : ${RAM_SIZE}MB"
echo "vCPU           : ${VCPU_COUNT}"
echo "Disk Size      : ${DISK_SIZE}G"
echo "VNC Port       : ${VNC_PORT}"
echo "RDP Host Port  : ${RDP_HOST_PORT}"
echo ""
read -p "Continue with this configuration? (y/n): " CONFIRM

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo -e "${RED}Installation cancelled.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Starting installation...${NC}\n"

# Update and install packages
echo -e "${YELLOW}[1/8] Installing required packages...${NC}"
sudo apt update && sudo apt install -y \
    qemu-system-x86 \
    qemu-kvm \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    bridge-utils \
    cpu-checker \
    wget \
    net-tools

# Get libvirt version
LIBVIRT_VERSION=$(virsh --version 2>/dev/null || echo "unknown")
echo -e "${GREEN}✓ Installed libvirt version: ${LIBVIRT_VERSION}${NC}"

# Configure libvirt
echo -e "${YELLOW}[2/8] Configuring libvirt...${NC}"

# Set LIBVIRT_DEFAULT_URI
export LIBVIRT_DEFAULT_URI="qemu:///system"
if ! grep -q "LIBVIRT_DEFAULT_URI" /etc/environment 2>/dev/null; then
    echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' | sudo tee -a /etc/environment
fi
if ! grep -q "LIBVIRT_DEFAULT_URI" ~/.bashrc 2>/dev/null; then
    echo 'export LIBVIRT_DEFAULT_URI="qemu:///system"' >> ~/.bashrc
fi

# Create necessary directories
sudo mkdir -p /var/lib/libvirt/images
sudo mkdir -p /var/lib/libvirt/boot

# Add user to libvirt group
if ! getent group libvirt > /dev/null 2>&1; then
    sudo groupadd libvirt
fi
sudo usermod -aG libvirt $USER || true

# Enable and start libvirtd
echo -e "${YELLOW}[3/8] Starting libvirt services...${NC}"
sudo systemctl enable libvirtd
sudo systemctl start libvirtd

# Wait for libvirtd to be ready
echo -e "${BLUE}→ Waiting for libvirtd to be ready...${NC}"
for i in {1..10}; do
    if sudo systemctl is-active --quiet libvirtd; then
        echo -e "${GREEN}✓ libvirtd is active${NC}"
        break
    fi
    if [ $i -eq 10 ]; then
        echo -e "${RED}✗ libvirtd failed to start!${NC}"
        sudo journalctl -u libvirtd -n 50 --no-pager
        cleanup_and_exit
    fi
    echo -e "${YELLOW}  Attempt $i/10...${NC}"
    sleep 2
done

# Verify virsh connection
echo -e "${BLUE}→ Testing virsh connection...${NC}"
if sudo virsh -c qemu:///system version &>/dev/null; then
    echo -e "${GREEN}✓ virsh connection successful${NC}"
else
    echo -e "${RED}✗ virsh connection failed!${NC}"
    cleanup_and_exit
fi

# Setup default network
echo -e "${YELLOW}[4/8] Setting up default network...${NC}"

# Check if default network exists
if ! sudo virsh -c qemu:///system net-info default &>/dev/null; then
    echo -e "${BLUE}→ Creating default network...${NC}"
    sudo tee /tmp/default-network.xml > /dev/null <<EOF
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
    sudo virsh -c qemu:///system net-define /tmp/default-network.xml
    sudo rm /tmp/default-network.xml
fi

# Start and autostart network
sudo virsh -c qemu:///system net-start default 2>/dev/null || echo "Default network already active"
sudo virsh -c qemu:///system net-autostart default

echo -e "${GREEN}✓ Default network configured${NC}"

# Download ISO
echo -e "${YELLOW}[5/8] Downloading Windows 10 LTSC ISO...${NC}"
cd /var/lib/libvirt/boot
if [ ! -f "Windows10-Ltsc.iso" ]; then
    sudo wget --no-check-certificate -O Windows10-Ltsc.iso \
        "https://archive.org/download/windows-10-ltsc-2021/windows%2010%20LTSC%2064.iso" || {
        echo -e "${RED}✗ Failed to download ISO!${NC}"
        cleanup_and_exit
    }
else
    echo -e "${GREEN}✓ ISO already exists, skipping download${NC}"
fi

ls -lh Windows10-Ltsc.iso
file Windows10-Ltsc.iso

# Create disk image
echo -e "${YELLOW}[6/8] Creating ${DISK_SIZE}G disk image...${NC}"
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# Setup swap
echo -e "${YELLOW}[7/8] Setting up ${SWAP_SIZE}G swap...${NC}"
if [ ! -f /swapfile ]; then
    sudo fallocate -l ${SWAP_SIZE}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    echo -e "${GREEN}✓ Swap created and activated${NC}"
else
    echo -e "${GREEN}✓ Swapfile already exists${NC}"
    sudo swapon /swapfile 2>/dev/null || echo "Swap already active"
fi

# Remove old VM if exists
echo -e "${YELLOW}[8/8] Creating Virtual Machine with RDP port forwarding...${NC}"
sudo virsh -c qemu:///system destroy ${VM_NAME} 2>/dev/null || true
sudo virsh -c qemu:///system undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# Create VM with port forwarding
echo -e "${BLUE}→ Installing VM...${NC}"

# Create VM XML with QEMU commandline for port forwarding
cat > /tmp/${VM_NAME}.xml <<EOF
<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>${VM_NAME}</name>
  <memory unit='MiB'>${RAM_SIZE}</memory>
  <vcpu placement='static'>${VCPU_COUNT}</vcpu>
  <os>
    <type arch='x86_64' machine='pc'>hvm</type>
    <boot dev='cdrom'/>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough'/>
  <clock offset='localtime'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/${VM_NAME}.img'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='/var/lib/libvirt/boot/Windows10-Ltsc.iso'/>
      <target dev='hdc' bus='ide'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='default'/>
      <model type='e1000'/>
    </interface>
    <graphics type='vnc' port='${VNC_PORT}' listen='0.0.0.0'/>
    <video>
      <model type='vga'/>
    </video>
  </devices>
  <qemu:commandline>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='user,id=hostnet1,hostfwd=tcp::${RDP_HOST_PORT}-:3389'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='e1000,netdev=hostnet1,id=net1'/>
  </qemu:commandline>
</domain>
EOF

# Define and start VM
sudo virsh -c qemu:///system define /tmp/${VM_NAME}.xml
sudo virsh -c qemu:///system start ${VM_NAME}

# Cleanup
rm /tmp/${VM_NAME}.xml

# Get host IP
HOST_IP=$(hostname -I | awk '{print $1}')

# Access info
echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo -e "${GREEN}✅ libvirt ${LIBVIRT_VERSION} installed!${NC}"
echo -e "${GREEN}✅ VM created successfully with RDP port forwarding!${NC}\n"

echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 1: Access VM via VNC to install Windows${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  VNC Address: ${HOST_IP}:${VNC_PORT}"
echo ""
echo "Use VNC viewer to connect:"
echo "  vncviewer ${HOST_IP}:${VNC_PORT}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 2: After Windows installation, enable RDP${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "In Windows:"
echo "  1. Right-click 'This PC' > Properties"
echo "  2. Click 'Remote settings'"
echo "  3. Enable 'Allow remote connections to this computer'"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Step 3: Connect via RDP${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "RDP is already configured! Connect to:"
echo -e "  ${GREEN}${HOST_IP}:${RDP_HOST_PORT}${NC}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}VM Management Commands${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  Start VM:      sudo virsh -c qemu:///system start ${VM_NAME}"
echo "  Stop VM:       sudo virsh -c qemu:///system shutdown ${VM_NAME}"
echo "  Force Stop:    sudo virsh -c qemu:///system destroy ${VM_NAME}"
echo "  Delete VM:     sudo virsh -c qemu:///system undefine ${VM_NAME} --remove-all-storage"
echo "  VM Status:     sudo virsh -c qemu:///system list --all"
echo "  VM Info:       sudo virsh -c qemu:///system dominfo ${VM_NAME}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Port Forwarding Info${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  RDP Forward:   ${HOST_IP}:${RDP_HOST_PORT} -> VM:3389"
echo "  Check Config:  sudo virsh -c qemu:///system dumpxml ${VM_NAME} | grep -A5 qemu:commandline"
echo "  View Port:     netstat -tulpn | grep ${RDP_HOST_PORT}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Logs and Debugging${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  VM Logs:       sudo tail -f /var/log/libvirt/qemu/${VM_NAME}.log"
echo "  Libvirt Logs:  sudo journalctl -u libvirtd -f"
echo "  Check Version: virsh -c qemu:///system version"
echo ""