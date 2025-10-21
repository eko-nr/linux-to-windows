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

# --- Fix default network (FIXED: handles transient network error) ---
header "Configuring default network"
step "Ensuring default network is persistent..."

# Stop and remove any existing default network (transient or not)
sudo virsh net-destroy default 2>/dev/null || true
sudo virsh net-undefine default 2>/dev/null || true

# Create persistent default network configuration
cat << 'EOF' | sudo tee /tmp/default-network.xml > /dev/null
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

# Define network persistently
sudo virsh net-define /tmp/default-network.xml
ok "Default network defined"

# Start network
if sudo virsh net-start default 2>/dev/null; then
  ok "Default network started"
else
  warn "Network already active"
fi

# Enable autostart (this should work now since network is persistent)
if sudo virsh net-autostart default 2>/dev/null; then
  ok "Default network set to autostart"
else
  warn "Could not set autostart (network may already be configured)"
fi

# Verify network status
sudo virsh net-list --all

# Cleanup temp file
sudo rm -f /tmp/default-network.xml

# --- Prepare autounattend.xml for fully automated Windows setup ---
header "Preparing Windows autounattend file"

AUTOUNATTEND_XML="/tmp/autounattend.xml"
AUTOUNATTEND_ISO="/var/lib/libvirt/images/${VM_NAME}-autounattend.iso"

cat > "$AUTOUNATTEND_XML" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-PnpCustomizationsWinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <DriverPaths>
        <Path>D:\viostor\w10\amd64</Path>
        <Path>D:\NetKVM\w10\amd64</Path>
        <Path>D:\Balloon\w10\amd64</Path>
        <Path>D:\pvpanic\w10\amd64</Path>
      </DriverPaths>
    </component>
    <component name="Microsoft-Windows-International-Core-WinPE"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <ImageInstall>
        <OSImage>
          <InstallFrom>
            <MetaData wcm:action="add">
              <Key>/IMAGE/INDEX</Key>
              <Value>1</Value>
            </MetaData>
          </InstallFrom>
          <InstallTo>
            <DiskID>0</DiskID>
            <PartitionID>1</PartitionID>
          </InstallTo>
          <WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <DiskConfiguration>
        <Disk wcm:action="add">
          <DiskID>0</DiskID>
          <WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions>
            <CreatePartition wcm:action="add">
              <Order>1</Order>
              <Type>Primary</Type>
              <Extend>true</Extend>
            </CreatePartition>
          </CreatePartitions>
        </Disk>
      </DiskConfiguration>
      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>Administrator</FullName>
        <Organization>AutoInstall</Organization>
      </UserData>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup"
               processorArchitecture="amd64"
               publicKeyToken="31bf3856ad364e35"
               language="neutral" versionScope="nonSxS">
      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>Administrator</Username>
        <Password>
          <Value>Password123!</Value>
          <PlainText>true</PlainText>
        </Password>
      </AutoLogon>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
      </OOBE>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -Command "Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0; Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'; Set-Service TermService -StartupType Automatic; Start-Service TermService"</CommandLine>
          <Description>Enable RDP</Description>
        </SynchronousCommand>
        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>powershell -ExecutionPolicy Bypass -Command "Start-Process msiexec.exe -ArgumentList '/i D:\guest-agent\qemu-ga-x86_64.msi /quiet /norestart' -Wait"</CommandLine>
          <Description>Install QEMU Guest Agent</Description>
        </SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
EOF

# Create ISO with the autounattend.xml
step "Creating autounattend ISO..."
sudo genisoimage -quiet -o "$AUTOUNATTEND_ISO" -V "AUTOUNATTEND" "$AUTOUNATTEND_XML"
ok "autounattend ISO created: $AUTOUNATTEND_ISO"

# --- Create VM with Performance Optimizations ---
header "Creating Virtual Machine"
sudo virt-install \
  --name "${VM_NAME}" \
  --ram "${RAM_SIZE}" \
  --vcpus "${VCPU_COUNT}",maxvcpus="${VCPU_COUNT}",sockets=1,cores="${VCPU_COUNT}",threads=1 \
  --cpu host-passthrough,cache.mode=passthrough \
  --cdrom "${ISO_LINK}" \
  --disk path="/var/lib/libvirt/images/${VM_NAME}.img",size="${DISK_SIZE}",bus=virtio,cache=none,io=threads,discard=unmap,detect_zeroes=unmap \
  --os-variant win10 \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0,port="${VNC_PORT}" \
  --boot cdrom,hd,menu=on \
  --disk "${VIRTIO_LINK}",device=cdrom \
  --disk path="${AUTOUNATTEND_ISO}",device=cdrom \
  --check path_in_use=off \
  --features hyperv_relaxed=on,hyperv_vapic=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191 \
  --clock hypervclock_present=yes \
  --noautoconsole

# --- Configure Huge Pages on Host ---
echo "⚡ Configuring huge pages for better memory performance..."

# Calculate huge pages needed (each huge page = 2MB)
# Formula: (VM_RAM_MB / 2) + small buffer
HUGEPAGES_NEEDED=$(( (RAM_SIZE / 2) + 256 ))

# Check available memory
AVAILABLE_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
MAX_HUGEPAGES=$(( (AVAILABLE_MEM_MB - 512) / 2 ))  # Leave 512MB for host

if (( HUGEPAGES_NEEDED > MAX_HUGEPAGES )); then
  warn "Not enough free memory for ${HUGEPAGES_NEEDED} huge pages"
  warn "Available: ${AVAILABLE_MEM_MB}MB, can allocate max ${MAX_HUGEPAGES} huge pages"
  warn "Skipping huge pages configuration - VM will use normal pages"
  SKIP_HUGEPAGES=true
else
  CURRENT_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
  
  if (( CURRENT_HUGEPAGES < HUGEPAGES_NEEDED )); then
    echo "Allocating ${HUGEPAGES_NEEDED} huge pages..."
    echo ${HUGEPAGES_NEEDED} | sudo tee /proc/sys/vm/nr_hugepages
    
    # Verify allocation succeeded
    ACTUAL_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages)
    if (( ACTUAL_HUGEPAGES < HUGEPAGES_NEEDED )); then
      warn "Could only allocate ${ACTUAL_HUGEPAGES} huge pages (requested ${HUGEPAGES_NEEDED})"
      warn "Skipping huge pages for VM - will use normal pages"
      SKIP_HUGEPAGES=true
    else
      # Make it permanent only if successful
      if ! grep -q "vm.nr_hugepages" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.nr_hugepages=${HUGEPAGES_NEEDED}" | sudo tee -a /etc/sysctl.conf
      else
        sudo sed -i "s/^vm.nr_hugepages=.*/vm.nr_hugepages=${HUGEPAGES_NEEDED}/" /etc/sysctl.conf
      fi
      ok "Huge pages configured: ${ACTUAL_HUGEPAGES}"
      SKIP_HUGEPAGES=false
    fi
  else
    ok "Huge pages already configured: ${CURRENT_HUGEPAGES}"
    SKIP_HUGEPAGES=false
  fi
fi

# --- Ensure vhost_net module is loaded on the host ---
echo "🔧 Checking for vhost_net module on host..."
if ! lsmod | grep -q vhost_net; then
  echo "➡️  Loading vhost_net kernel module..."
  sudo modprobe vhost_net
  # Make it load on boot
  if ! grep -q "vhost_net" /etc/modules 2>/dev/null; then
    echo "vhost_net" | sudo tee -a /etc/modules
  fi
fi

# --- Add vhost driver and multiqueue according to vCPU count ---
echo "⚙️  Enabling vhost accelerator and multiqueue (${VCPU_COUNT} queues)..."
sudo virt-xml "${VM_NAME}" --edit --network driver_name=vhost,driver_queues="${VCPU_COUNT}"

# --- Enable Huge Pages for VM ---
if [[ "$SKIP_HUGEPAGES" == "false" ]]; then
  echo "💾 Enabling huge pages for VM..."
  
  # Ensure VM is completely stopped
  if sudo virsh list --all | grep -q "${VM_NAME}.*running"; then
    echo "Stopping VM gracefully..."
    sudo virsh shutdown "${VM_NAME}" 2>/dev/null || true
    
    # Wait up to 30 seconds for clean shutdown
    for i in {1..30}; do
      if ! sudo virsh list --state-running | grep -q "${VM_NAME}"; then
        break
      fi
      echo -n "."
      sleep 1
    done
    echo ""
    
    # Force destroy if still running
    if sudo virsh list --state-running | grep -q "${VM_NAME}"; then
      echo "Force stopping VM..."
      sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
      sleep 2
    fi
  fi
  
  # Verify VM is stopped
  if sudo virsh list --state-running | grep -q "${VM_NAME}"; then
    err "Failed to stop VM, skipping huge pages configuration"
  else
    sudo virt-xml "${VM_NAME}" --edit --memorybacking hugepages=on
    ok "Huge pages enabled for VM"
    
    # Start VM
    echo "🚀 Starting VM with optimizations..."
    sudo virsh start "${VM_NAME}"
    ok "VM started successfully!"
  fi
else
  warn "Huge pages skipped - VM will use normal memory (still fast!)"
  ok "VM is ready with all other optimizations enabled"
fi

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
echo -e "${BLUE}STEP 1: Install Storage Driver (During Windows Setup)${NC}"
echo -e "  1. When asked ${YELLOW}'Where do you want to install Windows?'${NC}"
echo -e "  2. Click ${YELLOW}'Load driver'${NC}"
echo -e "  3. Browse to ${YELLOW}CD Drive (virtio-win)${NC} → ${YELLOW}viostor\\w10\\amd64${NC}"
echo -e "  4. Select ${YELLOW}'Red Hat VirtIO SCSI controller (E:\\amd64\\2k16\\viostor.inf)'${NC}"
echo -e "  5. Click ${YELLOW}'Next'${NC} - Your disk will appear!"
echo -e "  6. Continue with Windows installation"
echo ""
echo -e "${BLUE}STEP 2: Install Network Driver (After Windows Boots)${NC}"
echo -e "  1. Open ${YELLOW}'Device Manager'${NC} (Right-click Start → Device Manager)"
echo -e "  2. Look for ${YELLOW}'Ethernet Controller'${NC} with yellow warning ⚠️"
echo -e "  3. Right-click → ${YELLOW}'Update driver'${NC}"
echo -e "  4. Select ${YELLOW}'Browse my computer for drivers'${NC}"
echo -e "  5. Browse to ${YELLOW}CD Drive (virtio-win)${NC} → ${YELLOW}NetKVM\\w10\\amd64${NC}"
echo -e "  6. Click ${YELLOW}'Next'${NC} - Network will work immediately!"
echo -e "  7. Verify network: Run ${YELLOW}'ipconfig'${NC} in CMD to see your IP"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    VNC CONNECTION INFO                         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}→ Connect to VM via VNC:${NC}"
echo -e "  ${YELLOW}$(hostname -I | awk '{print $1}'):${VNC_PORT}${NC}"
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║              POST-INSTALLATION INSTRUCTIONS                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo -e "${BLUE}After installing network driver:${NC}"
echo -e "  1. Verify VM has IP: ${YELLOW}virsh domifaddr ${VM_NAME}${NC}"
echo -e "  2. Enable Remote Desktop (RDP) in Windows"
echo -e "  3. ${RED}Disable Windows Firewall${NC} to allow RDP connections"
echo -e "  4. Run port forwarding script: ${YELLOW}bash enable_port_forward_rdp.sh${NC}"
echo ""
echo -e "${BLUE}Optional: Install all virtio drivers at once${NC}"
echo -e "  - Run ${YELLOW}virtio-win-guest-tools.exe${NC} from virtio-win CD"
echo -e "  - This installs: Balloon driver, SPICE agent, and other optimizations"
echo ""
echo "Cached ISO: ${ISO_FILE}"
echo "Cached Drivers: ${VIRTIO_FILE}"
echo ""
echo -e "${GREEN}VM Management Commands:${NC}"
echo "  sudo virsh start ${VM_NAME}"
echo "  sudo virsh shutdown ${VM_NAME}"
echo "  sudo virsh destroy ${VM_NAME}  # Force stop"
echo "  sudo virsh domifaddr ${VM_NAME}  # Check VM IP"
echo "  sudo virsh undefine ${VM_NAME} --remove-all-storage  # Delete VM"
echo ""
ok "All done! Connect via VNC to start Windows installation."

# --- Wait for RDP port to open automatically ---
header "Waiting for Windows setup to complete (checking RDP)..."

echo "⏳ This can take around 10–25 minutes depending on your disk speed."
echo "   The script will automatically detect when Windows is ready for RDP."

for i in {1..120}; do
  # Ambil IP guest via qemu-guest-agent (jika sudah aktif)
  IP=$(sudo virsh domifaddr "${VM_NAME}" | awk '/ipv4/ {print $4}' | cut -d'/' -f1)

  if [[ -n "$IP" ]]; then
    if nc -z -w 5 "$IP" 3389 2>/dev/null; then
      echo ""
      ok "Windows installation and setup complete!"
      ok "RDP is active and ready to connect."
      echo ""
      echo "👉 Connect using:"
      echo "   mstsc /v:${IP}"
      echo "   Username: Administrator"
      echo "   Password: Password123!"
      echo ""
      break
    fi
  fi

  # Progress indicator
  echo -n "."
  sleep 15
done

echo ""
echo "If RDP didn’t appear yet, you can recheck later with:"
echo "  sudo virsh domifaddr ${VM_NAME}"
echo "and then test with:"
echo "  nc -zv <ip> 3389"
echo ""
ok "Script completed. VM will continue setup automatically if not done yet."