#!/bin/bash
# ============================================================
# Windows 10 LTSC Installer (Debian 13 Trixie)
# - Validates KVM support
# - Installs libvirt 11.8 LTS from GitHub if needed
# - Creates permanent ISO cache
# - Creates Windows 10 LTSC VM
# ============================================================

set -euo pipefail

# --- Styling ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Helper functions ---
cleanup_and_exit() {
    echo -e "\n${RED}❌ Cleaning up...${NC}"
    pkill -9 -f qemu 2>/dev/null || true
    pkill -9 -f libvirtd 2>/dev/null || true
    exit 1
}

header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
step()   { echo -e "${YELLOW}→ $1${NC}"; }
ok()     { echo -e "${GREEN}✓ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠ $1${NC}"; }
err()    { echo -e "${RED}✗ $1${NC}"; }

# --- OS Detection ---
header "Checking Operating System"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "Detected: $PRETTY_NAME"
    if [[ "$ID" != "debian" ]]; then
        err "Only Debian is supported."
        cleanup_and_exit
    fi
    if (( ${VERSION_ID%%.*} < 12 )); then
        warn "This script is optimized for Debian 13 (Trixie)."
        read -p "Continue anyway? (y/n): " RESP
        [[ ! $RESP =~ ^[Yy]$ ]] && cleanup_and_exit
    fi
else
    warn "Cannot detect OS, continuing..."
fi

# --- KVM Validation ---
header "Validating KVM Support"
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then
    err "CPU virtualization not supported!"
    cleanup_and_exit
fi
ok "CPU virtualization supported"

if [[ ! -e /dev/kvm ]]; then
    err "/dev/kvm not found! Enable virtualization in BIOS or VPS panel."
    cleanup_and_exit
fi

sudo chmod 666 /dev/kvm 2>/dev/null || true
if ! lsmod | grep -q kvm; then
    step "Loading KVM module..."
    grep -q vmx /proc/cpuinfo && sudo modprobe kvm_intel || true
    grep -q svm /proc/cpuinfo && sudo modprobe kvm_amd || true
fi

if ! lsmod | grep -q kvm; then
    err "Failed to load KVM module"
    cleanup_and_exit
fi
ok "KVM module active"

if systemd-detect-virt | grep -qE 'lxc|docker|openvz|container'; then
    err "Running inside container — KVM unavailable."
    cleanup_and_exit
fi
ok "Hardware virtualization available"

# --- User Configuration ---
header "VM Configuration"
read -p "Swap size (GB) [4]: " SWAP_SIZE; SWAP_SIZE=${SWAP_SIZE:-4}
read -p "VM name [win10ltsc]: " VM_NAME; VM_NAME=${VM_NAME:-win10ltsc}
read -p "RAM (MB) [4096]: " RAM_SIZE; RAM_SIZE=${RAM_SIZE:-4096}
read -p "vCPU [2]: " VCPU_COUNT; VCPU_COUNT=${VCPU_COUNT:-2}
read -p "Disk size (GB) [50]: " DISK_SIZE; DISK_SIZE=${DISK_SIZE:-50}
read -p "VNC port [5901]: " VNC_PORT; VNC_PORT=${VNC_PORT:-5901}

echo -e "\n${BLUE}Summary:${NC}"
echo "Swap: ${SWAP_SIZE}G"
echo "VM: ${VM_NAME}"
echo "RAM: ${RAM_SIZE}MB"
echo "vCPU: ${VCPU_COUNT}"
echo "Disk: ${DISK_SIZE}G"
echo "VNC: ${VNC_PORT}"
read -p "Proceed? (y/n): " CONFIRM
[[ ! $CONFIRM =~ ^[Yy]$ ]] && exit 0

# --- Dependencies ---
header "Installing Dependencies"
sudo apt update -y
sudo apt install -y \
  qemu-kvm bridge-utils virtinst virt-manager cpu-checker \
  wget git make gcc meson ninja-build pkg-config \
  libxml2-dev libdevmapper-dev libnl-3-dev libnl-route-3-dev \
  libyajl-dev libcurl4-gnutls-dev libglib2.0-dev libpciaccess-dev \
  libcap-ng-dev libselinux1-dev libsystemd-dev libapparmor-dev \
  libjson-c-dev python3-docutils

# --- Check virsh/libvirt version ---
header "Checking libvirt/virsh"
SKIP_BUILD=false
if command -v virsh &>/dev/null; then
    VIRSH_VER=$(virsh --version 2>/dev/null || echo "unknown")
    if [[ "$VIRSH_VER" == "11.8" ]]; then
        ok "virsh 11.8 detected — skipping source build"
        SKIP_BUILD=true
    else
        warn "Detected virsh version: $VIRSH_VER → upgrading to 11.8"
    fi
else
    warn "virsh not found, building libvirt 11.8"
fi

# --- Build libvirt 11.8 if needed ---
if [[ "$SKIP_BUILD" == false ]]; then
    header "Installing libvirt 11.8 LTS from GitHub"
    sudo systemctl stop libvirtd 2>/dev/null || true
    sudo apt remove -y libvirt-daemon-system libvirt-clients libvirt-daemon || true
    cd /usr/src
    sudo rm -rf libvirt
    sudo git clone --branch v11.8 --depth 1 https://github.com/libvirt/libvirt.git
    cd libvirt
    sudo meson setup build --prefix=/usr
    sudo ninja -C build
    sudo ninja -C build install
    sudo systemctl daemon-reexec
    sudo systemctl daemon-reload
    sudo systemctl enable --now libvirtd
    if systemctl is-active --quiet libvirtd; then
        ok "libvirt 11.8 running"
    else
        err "Failed to start libvirtd"
        cleanup_and_exit
    fi
fi

# --- Swap Configuration ---
header "Configuring Swap"
if [[ ! -f /swapfile ]]; then
    step "Creating ${SWAP_SIZE}G swap..."
    sudo fallocate -l ${SWAP_SIZE}G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile
    sudo swapon /swapfile
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "Swap created"
else
    ok "Swap already exists"
fi

# --- ISO Handling ---
header "Handling Windows ISO"
ISO_CACHE="/opt/vm-isos"
ISO_FILE="${ISO_CACHE}/Windows10-Ltsc.iso"
ISO_LINK="/var/lib/libvirt/boot/Windows10-Ltsc.iso"

sudo mkdir -p "$ISO_CACHE" /var/lib/libvirt/boot
if [[ ! -f "$ISO_FILE" ]]; then
    step "Downloading Windows 10 LTSC ISO (only once)..."
    sudo wget -O "$ISO_FILE" "https://archive.org/download/windows-10-ltsc-2021/windows%2010%20LTSC%2064.iso"
else
    ok "Using cached ISO at $ISO_FILE"
fi
sudo ln -sf "$ISO_FILE" "$ISO_LINK"

# --- Create Disk ---
header "Creating VM Disk"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 "/var/lib/libvirt/images/${VM_NAME}.img" ${DISK_SIZE}G
ok "Disk created"

# --- Remove old VM if exists ---
header "Cleaning Previous VM"
sudo virsh destroy "$VM_NAME" 2>/dev/null || true
sudo virsh undefine "$VM_NAME" --remove-all-storage 2>/dev/null || true

# --- Install VM ---
header "Creating Virtual Machine"
sudo virt-install \
  --name "$VM_NAME" \
  --ram "$RAM_SIZE" \
  --vcpus "$VCPU_COUNT" \
  --cdrom "$ISO_LINK" \
  --disk path="/var/lib/libvirt/images/${VM_NAME}.img",size="$DISK_SIZE" \
  --os-variant win10 \
  --network network=default \
  --graphics vnc,listen=0.0.0.0,port="$VNC_PORT" \
  --boot cdrom,hd,menu=on \
  --check path_in_use=off \
  --noautoconsole

# --- Done ---
header "Installation Complete"
ok "VM ${VM_NAME} created successfully"
echo "Access VNC: $(hostname -I | awk '{print $1}'):${VNC_PORT}"
echo "Cached ISO: ${ISO_FILE}"
echo ""
echo "Commands:"
echo "  sudo virsh start ${VM_NAME}"
echo "  sudo virsh shutdown ${VM_NAME}"
echo "  sudo virsh destroy ${VM_NAME}"
echo "  sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo ""
ok "Setup finished!"
