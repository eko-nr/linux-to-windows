#!/bin/bash
# ============================================================
# Windows 10 LTSC Installer for Debian 12+ / Ubuntu 22+
# Auto-detect system resources
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }
step()   { echo -e "${YELLOW}→ $1${NC}"; }
ok()     { echo -e "${GREEN}✓ $1${NC}"; }
warn()   { echo -e "${YELLOW}⚠ $1${NC}"; }
err()    { echo -e "${RED}✗ $1${NC}"; }
cleanup_and_exit() { echo -e "${RED}❌ Cleaning up and exiting...${NC}"; exit 1; }

# --- OS check ---
header "Checking OS"
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "Detected: $PRETTY_NAME"
  
  # Check if OS is Debian or Ubuntu
  if [[ "$ID" != "debian" ]] && [[ "$ID" != "ubuntu" ]]; then
    err "Only Debian and Ubuntu are supported"
    cleanup_and_exit
  fi
  
  # Version check for Debian
  if [[ "$ID" == "debian" ]]; then
    if (( ${VERSION_ID%%.*} < 12 )); then
      err "Debian 12 (Bookworm) or higher is required. Detected: Debian ${VERSION_ID}"
      cleanup_and_exit
    fi
    ok "Debian ${VERSION_ID} is supported"
  fi
  
  # Version check for Ubuntu
  if [[ "$ID" == "ubuntu" ]]; then
    UBUNTU_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
    if (( UBUNTU_MAJOR < 22 )); then
      err "Ubuntu 22.04 or higher is required. Detected: Ubuntu ${VERSION_ID}"
      cleanup_and_exit
    fi
    ok "Ubuntu ${VERSION_ID} is supported"
  fi
else 
  err "Cannot detect OS - /etc/os-release not found"
  cleanup_and_exit
fi

# --- KVM check ---
header "Checking KVM support"
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then err "CPU virtualization not supported"; cleanup_and_exit; fi
[[ ! -e /dev/kvm ]] && err "/dev/kvm missing" && cleanup_and_exit
sudo chmod 666 /dev/kvm || true
if ! lsmod | grep -q kvm; then
  warn "Loading KVM modules..."
  grep -q vmx /proc/cpuinfo && sudo modprobe kvm_intel || true
  grep -q svm /proc/cpuinfo && sudo modprobe kvm_amd || true
fi
ok "KVM ready"

if systemd-detect-virt | grep -qE 'lxc|docker|openvz|container'; then
  err "Running inside container — KVM unavailable."; cleanup_and_exit
fi

# --- Detect System Resources ---
header "Detecting System Resources"

# Detect total physical RAM (in MB)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
echo "Total Physical RAM: ${TOTAL_RAM_MB} MB"

# Detect total CPU cores
TOTAL_CPUS=$(nproc)
echo "Total CPU Cores: ${TOTAL_CPUS}"

# Detect total disk space on root partition (in GB)
TOTAL_DISK_GB=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
echo "Total Disk Space: ${TOTAL_DISK_GB} GB (Free: ${FREE_DISK_GB} GB)"

# --- VM Config ---
header "VM Configuration"
read -p "VM name [win10ltsc]: " VM_NAME; VM_NAME=${VM_NAME:-win10ltsc}

# RAM configuration (percentage)
read -p "RAM allocation (% of ${TOTAL_RAM_MB}MB) [50]: " RAM_PERCENT
RAM_PERCENT=${RAM_PERCENT:-50}
RAM_SIZE=$(( TOTAL_RAM_MB * RAM_PERCENT / 100 ))
echo "Allocated RAM: ${RAM_SIZE} MB (${RAM_PERCENT}% of total)"

# CPU configuration (auto-detect max)
MAX_VCPU=$TOTAL_CPUS
read -p "vCPU count (max: ${MAX_VCPU}) [2]: " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-2}
if (( VCPU_COUNT > MAX_VCPU )); then
  warn "Requested ${VCPU_COUNT} vCPUs exceeds maximum ${MAX_VCPU}, setting to ${MAX_VCPU}"
  VCPU_COUNT=$MAX_VCPU
fi
echo "Allocated vCPUs: ${VCPU_COUNT}"

# Disk configuration (fixed GB)
read -p "Disk size in GB (max: ${FREE_DISK_GB}GB free) [50]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-50}
if (( DISK_SIZE > FREE_DISK_GB )); then
  warn "Requested ${DISK_SIZE}GB exceeds available ${FREE_DISK_GB}GB, setting to ${FREE_DISK_GB}GB"
  DISK_SIZE=$FREE_DISK_GB
fi
if (( DISK_SIZE < 20 )); then
  warn "Requested disk size (${DISK_SIZE}GB) is too small, setting to 20GB minimum"
  DISK_SIZE=20
fi
echo "Allocated Disk: ${DISK_SIZE} GB"

# VNC port
read -p "VNC port [5901]: " VNC_PORT; VNC_PORT=${VNC_PORT:-5901}

# Swap size (fixed GB)
read -p "Swap size in GB [4]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}
if (( SWAP_SIZE < 1 )); then
  warn "Swap size too small, setting to 1GB minimum"
  SWAP_SIZE=1
fi
if (( SWAP_SIZE > 16 )); then
  warn "Swap size too large, setting to 16GB maximum"
  SWAP_SIZE=16
fi
echo "Allocated Swap: ${SWAP_SIZE} GB"

# --- Dependencies ---
header "Installing dependencies"
sudo apt update -y
sudo apt install -y \
 qemu-kvm bridge-utils virtinst virt-manager cpu-checker \
 wget git make gcc meson ninja-build pkg-config \
 libxml2-dev libdevmapper-dev libnl-3-dev libnl-route-3-dev \
 libyajl-dev libcurl4-gnutls-dev libglib2.0-dev libpciaccess-dev \
 libcap-ng-dev libselinux1-dev libsystemd-dev libapparmor-dev \
 libjson-c-dev libxslt1-dev xsltproc gettext libreadline-dev \
 libncurses5-dev libtirpc-dev python3-docutils \
 libgnutls28-dev gnutls-bin

# --- libvirt check ---
header "Checking libvirt/virsh"
SKIP_BUILD=false
if command -v virsh &>/dev/null; then
  VER=$(virsh --version 2>/dev/null || echo "unknown")
  if [[ "$VER" == "11.8.0" ]]; then
    ok "libvirt 11.8.0 detected — skipping build"
    SKIP_BUILD=true
  else
    warn "Detected libvirt version $VER → rebuilding to 11.8.0"
  fi
else
  warn "libvirt not found, building 11.8.0"
fi

# --- Build libvirt 11.8.0 ---
if [[ "$SKIP_BUILD" == false ]]; then
  header "Building libvirt 11.8.0 from GitHub"
  sudo systemctl stop libvirtd 2>/dev/null || true
  sudo apt remove -y libvirt-daemon-system libvirt-clients libvirt-daemon || true
  cd /usr/src
  sudo rm -rf libvirt
  step "Cloning libvirt v11.8.0..."
  if ! sudo git clone --branch v11.8.0 --depth 1 https://github.com/libvirt/libvirt.git; then
    warn "Tag v11.8.0 not found, trying fallback v11.8.1..."
    sudo git clone --branch v11.8.1 --depth 1 https://github.com/libvirt/libvirt.git || {
      warn "Fallback failed, using v11.7.0"
      sudo git clone --branch v11.7.0 --depth 1 https://github.com/libvirt/libvirt.git
    }
  fi

  cd libvirt
  step "Configuring Meson..."
  sudo meson setup build --prefix=/usr -Ddriver_libvirtd=enabled -Ddriver_remote=enabled -Dsystem=true
  step "Building with Ninja..."
  sudo ninja -C build
  step "Installing..."
  sudo ninja -C build install

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable --now libvirtd
  if systemctl is-active --quiet libvirtd; then
    ok "libvirt 11.8.0 built successfully"
  else
    err "Failed to start libvirtd"
    cleanup_and_exit
  fi
fi

# --- Swap setup ---
header "Configuring Swap"
if [[ ! -f /swapfile ]]; then
  sudo fallocate -l ${SWAP_SIZE}G /swapfile
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  ok "Swap ${SWAP_SIZE}G created"
else ok "Swap already exists"; fi

# --- ISO Cache ---
header "Preparing Windows ISO"
ISO_CACHE="/opt/vm-isos"
ISO_FILE="${ISO_CACHE}/Windows10-Ltsc.iso"
ISO_LINK="/var/lib/libvirt/boot/Windows10-Ltsc.iso"
sudo mkdir -p "$ISO_CACHE" /var/lib/libvirt/boot
if [[ ! -f "$ISO_FILE" ]]; then
  step "Downloading Windows 10 LTSC ISO..."
  sudo wget -O "$ISO_FILE" "https://archive.org/download/windows-10-ltsc-enterprise-feb-2019/17763.2028/Windows_10__ENT_LTSC_OEM-June_x64_multilingual%5B17763.2028%5D.iso"
else ok "Using cached ISO: $ISO_FILE"; fi
sudo ln -sf "$ISO_FILE" "$ISO_LINK"

# --- Download virtio drivers ---
header "Preparing virtio Drivers"
VIRTIO_FILE="${ISO_CACHE}/virtio-win.iso"
VIRTIO_LINK="/var/lib/libvirt/boot/virtio-win.iso"
if [[ ! -f "$VIRTIO_FILE" ]]; then
  step "Downloading latest virtio-win drivers..."
  sudo wget -O "$VIRTIO_FILE" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
  ok "virtio drivers downloaded"
else 
  ok "Using cached virtio drivers: $VIRTIO_FILE"
fi
sudo ln -sf "$VIRTIO_FILE" "$VIRTIO_LINK"

# --- Create Disk ---
header "Creating VM Disk"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G
ok "Disk ${DISK_SIZE}G ready"

# --- Remove old VM ---
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --remove-all-storage 2>/dev/null || true

# --- Fix AppArmor issue ---
header "Fixing AppArmor configuration"
if grep -q '^security_driver' /etc/libvirt/qemu.conf 2>/dev/null; then
  sudo sed -i 's/^security_driver.*/security_driver = "none"/' /etc/libvirt/qemu.conf
else
  echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf
fi
sudo systemctl restart libvirtd
ok "AppArmor disabled for libvirt (using security_driver=none)"

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

# --- Create VM ---
header "Creating Virtual Machine"
sudo virt-install \
  --name ${VM_NAME} \
  --ram ${RAM_SIZE} \
  --vcpus ${VCPU_COUNT} \
  --cdrom "$ISO_LINK" \
  --disk path=/var/lib/libvirt/images/${VM_NAME}.img,size=${DISK_SIZE},bus=virtio \
  --os-variant win10 \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0,port=${VNC_PORT} \
  --boot cdrom,hd,menu=on \
  --disk "$VIRTIO_LINK",device=cdrom \
  --check path_in_use=off \
  --noautoconsole

# --- Upgrade NIC to virtio ---
header "Upgrading Network Interface to virtio"
step "Stopping VM to modify configuration..."
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sleep 2

step "Changing NIC model to virtio for better performance..."
sudo virt-xml ${VM_NAME} --edit --network model=virtio
ok "Network interface upgraded to virtio"

# --- Upgrade NIC to virtio ---
header "Upgrading Network Interface to virtio"
step "Stopping VM to modify configuration..."
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sleep 2

step "Changing NIC model to virtio for better performance..."
sudo virt-xml ${VM_NAME} --edit --network model=virtio
ok "Network interface upgraded to virtio"

# --- Finish ---
header "Installation Complete"
ok "VM ${VM_NAME} created successfully!"
echo ""
echo "System Resources:"
echo "  Total RAM: ${TOTAL_RAM_MB} MB → Allocated: ${RAM_SIZE} MB (${RAM_PERCENT}%)"
echo "  Total CPUs: ${TOTAL_CPUS} → Allocated: ${VCPU_COUNT} vCPUs"
echo "  Free Disk: ${FREE_DISK_GB} GB → Allocated: ${DISK_SIZE} GB"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    IMPORTANT NOTICE                            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}⚠ VM uses virtio drivers for maximum performance${NC}"
echo -e "${YELLOW}⚠ virtio-win.iso is attached as second CD-ROM${NC}"
echo ""
echo -e "${BLUE}During Windows installation:${NC}"
echo -e "  1. When asked 'Where do you want to install Windows?'"
echo -e "  2. Click ${YELLOW}'Load driver'${NC}"
echo -e "  3. Browse to ${YELLOW}CD Drive (virtio-win)${NC} → ${YELLOW}viostor\\w10\\amd64${NC}"
echo -e "  4. Install the storage driver to see your disk"
echo -e "  5. After Windows installs, go to Device Manager"
echo -e "  6. Install network driver from ${YELLOW}virtio-win CD:\\NetKVM\\w10\\amd64${NC}"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    VNC CONNECTION INFO                         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}→ VM is ready to accept VNC connections on:${NC}"
echo -e "  ${YELLOW}$(hostname -I | awk '{print $1}'):${VNC_PORT}${NC}"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    RDP SETUP INSTRUCTIONS                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${YELLOW}To enable RDP access:${NC}"
echo -e "  1. Connect to VM via VNC first"
echo -e "  2. Inside Windows, enable Remote Desktop (RDP)"
echo -e "  3. ${RED}Disable Windows Firewall${NC} to allow RDP connections"
echo -e "  4. Run the port forwarding script:"
echo -e "     ${BLUE}bash enable_port_forward_rdp.sh${NC}"
echo ""
echo "Cached ISO: ${ISO_FILE}"
echo ""
echo -e "${GREEN}VM Management Commands:${NC}"
echo "  sudo virsh start ${VM_NAME}"
echo "  sudo virsh shutdown ${VM_NAME}"
echo "  sudo virsh destroy ${VM_NAME}"
echo "  sudo virsh undefine ${VM_NAME} --remove-all-storage"
echo ""
ok "All done!"