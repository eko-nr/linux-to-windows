#!/bin/bash

# ============================================================
# VM Windows 10 LTSC Installer for Debian 11 (KVM)
# With libvirt 11.8 LTS from GitHub + ISO Cache Fix
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

echo -e "${GREEN}=== Windows 10 LTSC Installer for Debian 11 (KVM) ===${NC}\n"

cleanup_and_exit() {
    echo -e "\n${RED}❌ Cleaning up processes and exiting...${NC}"
    pkill -9 -f qemu 2>/dev/null
    pkill -9 -f libvirt 2>/dev/null
    pkill -9 -f virt 2>/dev/null
    exit 1
}

# --- Check OS ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "debian" ]]; then
        echo -e "${RED}✗ Only supported on Debian${NC}"
        cleanup_and_exit
    fi
    if [[ "$VERSION_ID" != "11" ]]; then
        echo -e "${YELLOW}⚠ Optimized for Debian 11 (Bullseye), detected ${VERSION_ID}${NC}"
        read -p "Continue anyway? (y/n): " CONT
        [[ ! $CONT =~ ^[Yy]$ ]] && cleanup_and_exit
    fi
fi

# --- KVM Validation ---
echo -e "${BLUE}[CHECK] Validating KVM support...${NC}"
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    echo -e "${RED}✗ CPU does not support virtualization!${NC}"
    cleanup_and_exit
fi

if [ ! -e /dev/kvm ]; then
    echo -e "${RED}✗ /dev/kvm not found${NC}"
    cleanup_and_exit
fi

sudo chmod 666 /dev/kvm 2>/dev/null
if ! lsmod | grep -q kvm; then
    echo -e "${YELLOW}⚠ Loading KVM modules...${NC}"
    grep -q vmx /proc/cpuinfo && sudo modprobe kvm_intel
    grep -q svm /proc/cpuinfo && sudo modprobe kvm_amd
fi

if ! lsmod | grep -q kvm; then
    echo -e "${RED}✗ Failed to load KVM module${NC}"
    cleanup_and_exit
fi
echo -e "${GREEN}✓ KVM ready${NC}\n"

# --- VM Config ---
read -p "Swap size (GB) [4]: " SWAP_SIZE; SWAP_SIZE=${SWAP_SIZE:-4}
read -p "VM name [win10ltsc]: " VM_NAME; VM_NAME=${VM_NAME:-win10ltsc}
read -p "RAM (MB) [2048]: " RAM_SIZE; RAM_SIZE=${RAM_SIZE:-2048}
read -p "vCPU [2]: " VCPU_COUNT; VCPU_COUNT=${VCPU_COUNT:-2}
read -p "Disk size (GB) [40]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-40}
read -p "VNC port [5901]: " VNC_PORT; VNC_PORT=${VNC_PORT:-5901}

# --- Dependencies ---
echo -e "${YELLOW}[1/9] Installing dependencies...${NC}"
sudo apt update && sudo apt install -y \
  qemu-kvm bridge-utils virtinst virt-manager cpu-checker \
  wget git make gcc meson ninja-build pkg-config \
  libxml2-dev libdevmapper-dev libnl-3-dev libnl-route-3-dev \
  libyajl-dev libcurl4-gnutls-dev libglib2.0-dev libpciaccess-dev \
  libcap-ng-dev libselinux1-dev libsystemd-dev libapparmor-dev \
  libjson-c-dev python3-docutils

# --- Check virsh ---
echo -e "${YELLOW}[2/9] Checking libvirt...${NC}"
SKIP_BUILD=false
if command -v virsh &>/dev/null; then
    VIRSH_VER=$(virsh --version 2>/dev/null | head -n1)
    if [[ "$VIRSH_VER" == "11.8" ]]; then
        echo -e "${GREEN}✓ virsh 11.8 already installed${NC}"
        SKIP_BUILD=true
    else
        echo -e "${YELLOW}⚠ virsh version $VIRSH_VER, rebuilding...${NC}"
    fi
else
    echo -e "${YELLOW}No virsh found, building libvirt 11.8${NC}"
fi

# --- Build libvirt 11.8 if needed ---
if [ "$SKIP_BUILD" = false ]; then
    sudo systemctl stop libvirtd 2>/dev/null || true
    sudo apt remove -y libvirt-daemon-system libvirt-clients libvirt-daemon 2>/dev/null || true
    cd /usr/src
    sudo rm -rf libvirt 2>/dev/null
    sudo git clone --branch v11.8 --depth 1 https://github.com/libvirt/libvirt.git
    cd libvirt
    sudo meson setup build --prefix=/usr
    sudo ninja -C build
    sudo ninja -C build install
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl enable --now libvirtd
    if systemctl is-active --quiet libvirtd; then
        echo -e "${GREEN}✓ libvirt 11.8 installed successfully${NC}"
    else
        echo -e "${RED}✗ libvirt failed to start${NC}"
        cleanup_and_exit
    fi
fi

# --- Swap setup ---
echo -e "${YELLOW}[3/9] Configuring ${SWAP_SIZE}G swap...${NC}"
if [ ! -f /swapfile ]; then
    sudo fallocate -l ${SWAP_SIZE}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
else
    echo -e "${GREEN}✓ Swap already exists${NC}"
fi

# --- ISO cache setup ---
ISO_CACHE="/opt/vm-isos"
ISO_FILE="${ISO_CACHE}/Windows10-Ltsc.iso"
ISO_LINK="/var/lib/libvirt/boot/Windows10-Ltsc.iso"

echo -e "${YELLOW}[4/9] Checking ISO cache...${NC}"
sudo mkdir -p "$ISO_CACHE" /var/lib/libvirt/boot

if [ ! -f "$ISO_FILE" ]; then
    echo -e "${YELLOW}→ Downloading Windows 10 LTSC ISO (once only)...${NC}"
    sudo wget -O "$ISO_FILE" "https://archive.org/download/windows-10-ltsc-2021/windows%2010%20LTSC%2064.iso"
else
    echo -e "${GREEN}✓ Using cached ISO at $ISO_FILE${NC}"
fi

# Buat symlink ke direktori boot
sudo ln -sf "$ISO_FILE" "$ISO_LINK"

# --- Disk ---
echo -e "${YELLOW}[5/9] Creating ${DISK_SIZE}G disk...${NC}"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G

# --- Cleanup old VM ---
echo -e "${YELLOW}[6/9] Cleaning previous VM (if any)...${NC}"
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# --- Create VM ---
echo -e "${YELLOW}[7/9] Creating Virtual Machine...${NC}"
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom "$ISO_LINK" \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,size=${DISK_SIZE} \
  --os-variant win10 \
  --network network=default \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --check path_in_use=off \
  --noautoconsole

# --- Done ---
echo -e "\n${GREEN}=== Installation Complete ===${NC}"
echo "Access VM via VNC: $(hostname -I | awk '{print $1}'):${VNC_PORT}"
echo "To manage:"
echo "  Start VM:   sudo virsh start ${VM_NAME}"
echo "  Stop VM:    sudo virsh shutdown ${VM_NAME}"
echo "  Delete VM:  sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo "  Logs:       sudo journalctl -u libvirtd -f"
echo -e "${YELLOW}ISO cached at: $ISO_FILE${NC}"
