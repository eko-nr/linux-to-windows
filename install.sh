#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== VM Windows 10 LTSC Installation Script for Debian 11 ===${NC}\n"
echo -e "${BLUE}With libvirt 11.8.0 LTS build from source and RDP Port Forwarding${NC}\n"

# Function for cleanup and exit
cleanup_and_exit() {
    echo -e "\n${RED}❌ Cleaning up processes and exiting...${NC}"
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
    
    if grep -q vmx /proc/cpuinfo; then
        sudo modprobe kvm_intel 2>/dev/null
    elif grep -q svm /proc/cpuinfo; then
        sudo modprobe kvm_amd 2>/dev/null
    fi
    
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

# Stop existing libvirt if running
echo -e "${YELLOW}[0/10] Stopping existing libvirt services...${NC}"
sudo systemctl stop libvirtd 2>/dev/null || true
sudo systemctl stop virtlogd 2>/dev/null || true

# Install build dependencies and basic packages
echo -e "${YELLOW}[1/10] Installing build dependencies and base packages...${NC}"
sudo apt update && sudo apt install -y \
    build-essential \
    git \
    meson \
    ninja-build \
    python3-docutils \
    python3-pip \
    libxml2-dev \
    libxml2-utils \
    libgnutls28-dev \
    libdevmapper-dev \
    libcurl4-gnutls-dev \
    libpciaccess-dev \
    libssh2-1-dev \
    libnl-3-dev \
    libnl-route-3-dev \
    libyajl-dev \
    libudev-dev \
    libpcap-dev \
    libnuma-dev \
    libnetcf-dev \
    libsanlock-dev \
    libcap-ng-dev \
    libselinux1-dev \
    libaudit-dev \
    libreadline-dev \
    libtirpc-dev \
    libglusterfs-dev \
    libiscsi-dev \
    xsltproc \
    qemu-kvm \
    qemu-utils \
    bridge-utils \
    cpu-checker \
    wget \
    pkg-config

# Build and install libvirt 11.8.0 from source
echo -e "${YELLOW}[2/10] Building libvirt 11.8.0 LTS from source (this may take 10-20 minutes)...${NC}"

LIBVIRT_VERSION="11.8.0"
LIBVIRT_BUILD_DIR="/tmp/libvirt-build"

# Remove old build directory if exists
sudo rm -rf ${LIBVIRT_BUILD_DIR}
mkdir -p ${LIBVIRT_BUILD_DIR}
cd ${LIBVIRT_BUILD_DIR}

echo -e "${BLUE}→ Downloading libvirt ${LIBVIRT_VERSION}...${NC}"
wget https://libvirt.org/sources/libvirt-${LIBVIRT_VERSION}.tar.xz

echo -e "${BLUE}→ Extracting source...${NC}"
tar -xf libvirt-${LIBVIRT_VERSION}.tar.xz
cd libvirt-${LIBVIRT_VERSION}

echo -e "${BLUE}→ Configuring build...${NC}"
meson setup build \
    --prefix=/usr \
    --sysconfdir=/etc \
    --localstatedir=/var \
    -Ddriver_qemu=enabled \
    -Ddriver_network=enabled \
    -Dstorage_fs=enabled \
    -Dstorage_disk=enabled \
    -Dstorage_dir=enabled

echo -e "${BLUE}→ Compiling (using all CPU cores)...${NC}"
ninja -C build

echo -e "${BLUE}→ Installing libvirt ${LIBVIRT_VERSION}...${NC}"
sudo ninja -C build install

# Configure libvirt
echo -e "${YELLOW}[3/10] Configuring libvirt...${NC}"
sudo mkdir -p /etc/libvirt
sudo mkdir -p /var/lib/libvirt/images
sudo mkdir -p /var/lib/libvirt/boot
sudo mkdir -p /var/log/libvirt/qemu

# Create systemd service files if not exist
if [ ! -f /etc/systemd/system/libvirtd.service ]; then
    echo -e "${BLUE}→ Creating libvirtd systemd service...${NC}"
    sudo tee /etc/systemd/system/libvirtd.service > /dev/null <<EOF
[Unit]
Description=Virtualization daemon
Requires=virtlogd.socket
Before=libvirt-guests.service
After=network.target
After=dbus.service
After=iscsid.service
After=apparmor.service
After=local-fs.target
After=remote-fs.target
Documentation=man:libvirtd(8)
Documentation=https://libvirt.org

[Service]
Type=notify
ExecStart=/usr/sbin/libvirtd --timeout 120
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
KillMode=process

[Install]
WantedBy=multi-user.target
Also=virtlogd.socket
EOF
fi

if [ ! -f /etc/systemd/system/virtlogd.service ]; then
    echo -e "${BLUE}→ Creating virtlogd systemd service...${NC}"
    sudo tee /etc/systemd/system/virtlogd.service > /dev/null <<EOF
[Unit]
Description=Virtual machine log manager
Requires=virtlogd.socket
Before=libvirtd.service
Documentation=man:virtlogd(8)
Documentation=https://libvirt.org

[Service]
ExecStart=/usr/sbin/virtlogd
ExecReload=/bin/kill -USR1 \$MAINPID
Restart=on-failure

[Install]
Also=virtlogd.socket
EOF
fi

if [ ! -f /etc/systemd/system/virtlogd.socket ]; then
    echo -e "${BLUE}→ Creating virtlogd socket...${NC}"
    sudo tee /etc/systemd/system/virtlogd.socket > /dev/null <<EOF
[Unit]
Description=Virtual machine log manager socket
Before=libvirtd.service

[Socket]
ListenStream=/var/run/libvirt/virtlogd-sock
SocketMode=0600

[Install]
WantedBy=sockets.target
EOF
fi

# Reload systemd and start services
echo -e "${YELLOW}[4/10] Starting libvirt services...${NC}"
sudo systemctl daemon-reload
sudo systemctl enable libvirtd virtlogd.socket
sudo systemctl start virtlogd.socket
sudo systemctl start libvirtd

# Wait for libvirtd to be ready
sleep 3

# Verify installation
echo -e "${BLUE}→ Verifying libvirt installation...${NC}"
INSTALLED_VERSION=$(virsh --version 2>/dev/null)
if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ libvirt ${INSTALLED_VERSION} installed successfully${NC}"
else
    echo -e "${RED}✗ Failed to verify libvirt installation!${NC}"
    cleanup_and_exit
fi

# Setup default network
echo -e "${YELLOW}[5/10] Setting up default network...${NC}"
sudo virsh net-start default 2>/dev/null || echo "Default network already active"
sudo virsh net-autostart default

# Check KVM
echo -e "${YELLOW}[6/10] Checking KVM modules...${NC}"
lsmod | grep kvm

# Download ISO
echo -e "${YELLOW}[7/10] Downloading Windows 10 Tiny ISO...${NC}"
cd /var/lib/libvirt/boot
if [ ! -f "Windows10-Ltsc.iso" ]; then
    sudo wget -O Windows10-Ltsc.iso "https://archive.org/download/windows-10-ltsc-2021/windows%2010%20LTSC%2064.iso"
else
    echo "ISO already exists, skipping download."
fi

ls -lh Windows10-Ltsc.iso
file Windows10-Ltsc.iso

# Create disk image
echo -e "${YELLOW}[8/10] Creating ${DISK_SIZE}G disk image...${NC}"
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# Setup swap
echo -e "${YELLOW}[9/10] Setting up ${SWAP_SIZE}G swap...${NC}"
if [ ! -f /swapfile ]; then
    sudo fallocate -l ${SWAP_SIZE}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
    fi
    echo "Swap created and activated successfully."
else
    echo "Swapfile already exists."
    sudo swapon /swapfile 2>/dev/null || echo "Swap already active."
fi

# Remove old VM if exists
echo -e "${YELLOW}[10/10] Cleaning up old VM (if exists)...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# Install VM
echo -e "${YELLOW}[10/10] Creating Virtual Machine...${NC}"
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom /var/lib/libvirt/boot/Windows10-Ltsc.iso \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,size=${DISK_SIZE} \
  --os-variant win10 \
  --network network=default \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --check path_in_use=off \
  --noautoconsole

# Wait for VM to be fully created
sleep 5

# Setup RDP port forwarding using QEMU commandline
echo -e "\n${YELLOW}Setting up RDP port forwarding via libvirt/QEMU...${NC}"

# Get the host's main IP
HOST_IP=$(hostname -I | awk '{print $1}')

# Stop VM to modify configuration
echo -e "${BLUE}→ Stopping VM to add port forwarding...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || true

# Edit VM XML to add QEMU commandline for port forwarding
echo -e "${BLUE}→ Adding QEMU port forwarding to VM configuration...${NC}"

# Export current XML
sudo virsh dumpxml ${VM_NAME} > /tmp/${VM_NAME}.xml

# Check if qemu namespace is already defined
if ! grep -q "xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'" /tmp/${VM_NAME}.xml; then
    # Add qemu namespace to domain tag
    sed -i "s|<domain type='kvm'>|<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>|" /tmp/${VM_NAME}.xml
fi

# Remove closing </domain> tag temporarily
sed -i 's|</domain>||g' /tmp/${VM_NAME}.xml

# Add QEMU commandline for port forwarding if not exists
if ! grep -q "qemu:commandline" /tmp/${VM_NAME}.xml; then
    cat >> /tmp/${VM_NAME}.xml <<EOF
  <qemu:commandline>
    <qemu:arg value='-netdev'/>
    <qemu:arg value='user,id=net0,hostfwd=tcp::${RDP_HOST_PORT}-:3389'/>
    <qemu:arg value='-device'/>
    <qemu:arg value='e1000,netdev=net0'/>
  </qemu:commandline>
</domain>
EOF
else
    # Close domain tag if commandline already exists
    echo "</domain>" >> /tmp/${VM_NAME}.xml
fi

# Undefine and redefine VM with new configuration
sudo virsh undefine ${VM_NAME}
sudo virsh define /tmp/${VM_NAME}.xml

echo -e "${GREEN}✓ RDP port forwarding configured: ${HOST_IP}:${RDP_HOST_PORT} -> VM:3389${NC}"

# Start VM with new configuration
echo -e "${BLUE}→ Starting VM with port forwarding...${NC}"
sudo virsh start ${VM_NAME}

echo -e "${GREEN}✓ VM started successfully with RDP forwarding enabled${NC}"

# Access info
echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo -e "${GREEN}✅ libvirt ${INSTALLED_VERSION} (LTS 11.8.0) installed from source!${NC}"
echo -e "${GREEN}✅ VM created successfully!${NC}\n"

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
echo "  Start VM:      sudo virsh start ${VM_NAME}"
echo "  Stop VM:       sudo virsh shutdown ${VM_NAME}"
echo "  Force Stop:    sudo virsh destroy ${VM_NAME}"
echo "  Delete VM:     sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo "  VM Status:     sudo virsh list --all"
echo "  VM IP:         sudo virsh domifaddr ${VM_NAME}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Port Forwarding Management${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  Check Config:  sudo virsh dumpxml ${VM_NAME} | grep -A5 qemu:commandline"
echo "  View RDP Port: netstat -tulpn | grep ${RDP_HOST_PORT}"
echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Logs and Debugging${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════${NC}"
echo "  VM Logs:       sudo tail -f /var/log/libvirt/qemu/${VM_NAME}.log"
echo "  Libvirt Logs:  sudo journalctl -u libvirtd -f"
echo "  Check Version: virsh --version"
echo ""