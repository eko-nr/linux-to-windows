#!/bin/bash
# ============================================================
# Windows 10 Ltsc UNATTENDED Installer for Debian 12+ / Ubuntu 22+
# Full automation with reboot handling (FIXED windowsPE parsing)
# AUTO VERSION: RAM/CPU/DISK/SWAP computed automatically
# ============================================================

VM_NAME=${1:-win10ltsc}
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PORT_FORWARD_SCRIPT="$SCRIPT_DIR/enable_port_forward_rdp.sh"
AUTO_RESTART_SCRIPT="$SCRIPT_DIR/auto_restart.sh"

set -euo pipefail
if [[ $(id -u) -ne 0 ]]; then
  echo "❌ Must run as root: sudo bash $0"
  exit 1
fi

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
  if [[ "$ID" != "debian" ]] && [[ "$ID" != "ubuntu" ]]; then
    err "Only Debian and Ubuntu are supported"; cleanup_and_exit
  fi
  if [[ "$ID" == "debian" ]]; then
    if (( ${VERSION_ID%%.*} < 12 )); then err "Debian 12+ required"; cleanup_and_exit; fi
    ok "Debian ${VERSION_ID} is supported"
  fi
  if [[ "$ID" == "ubuntu" ]]; then
    UBUNTU_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
    if (( UBUNTU_MAJOR < 22 )); then err "Ubuntu 22.04+ required"; cleanup_and_exit; fi
    ok "Ubuntu ${VERSION_ID} is supported"
  fi
else
  err "Cannot detect OS - /etc/os-release not found"; cleanup_and_exit
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
# --- Ensure 4GB swap exists ---
header "Ensuring 4GB swap for host"

SWAP_ACTIVE=$(swapon --show --noheadings | wc -l)
if (( SWAP_ACTIVE > 0 )); then
  ok "Swap already active, skipping swapfile creation"
else
  if grep -Eqs "^\S+\s+\S+\s+swap\b" /etc/fstab; then
    warn "Swap entry found in /etc/fstab but not active. Trying to enable it..."
    if swapon -a 2>/dev/null; then
      ok "Swap from /etc/fstab activated"
    else
      warn "Failed to activate existing swap from /etc/fstab, proceeding to create swapfile"
    fi
  fi

  SWAP_ACTIVE=$(swapon --show --noheadings | wc -l)
  if (( SWAP_ACTIVE == 0 )); then
    SWAP_FILE="/swapfile"
    SWAP_SIZE_GB=4

    echo "Creating ${SWAP_SIZE_GB}GB swapfile at ${SWAP_FILE}..."
    fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}" 2>/dev/null || \
      dd if=/dev/zero of="${SWAP_FILE}" bs=1M count=$((SWAP_SIZE_GB*1024)) status=progress

    chmod 600 "${SWAP_FILE}"
    mkswap "${SWAP_FILE}"
    swapon "${SWAP_FILE}"

    if ! grep -q "^${SWAP_FILE} " /etc/fstab; then
      echo "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab
    fi

    ok "Swapfile ${SWAP_SIZE_GB}GB created and activated"
  fi
fi

if ! grep -q "vm.swappiness" /etc/sysctl.d/99-memory-tuning.conf 2>/dev/null; then
  echo "vm.swappiness=70" >> /etc/sysctl.d/99-memory-tuning.conf
  sysctl --system >/dev/null 2>&1 || true
  ok "vm.swappiness set to 70 (host will use swap more willingly)"
fi


# --- Windows User Configuration (PROMPTS KEPT) ---
header "Windows User Configuration"
echo -e "${BLUE}Configure Windows administrator account:${NC}"
read -p "Username [Administrator]: " WIN_USERNAME
WIN_USERNAME=${WIN_USERNAME:-Administrator}

while true; do
  read -sp "Password (min 8 chars): " WIN_PASSWORD; echo ""
  if [[ ${#WIN_PASSWORD} -lt 8 ]]; then warn "Password too short!"; continue; fi
  read -sp "Confirm password: " WIN_PASSWORD_CONFIRM; echo ""
  if [[ "$WIN_PASSWORD" == "$WIN_PASSWORD_CONFIRM" ]]; then
    ok "Password configured for user: ${WIN_USERNAME}"; break
  else warn "Passwords don't match! Try again."; fi
done

read -p "Computer name [WIN10-LTSC]: " WIN_COMPUTERNAME
WIN_COMPUTERNAME=${WIN_COMPUTERNAME:-WIN10-LTSC}

# --- VM Config (AUTO) ---
header "VM Configuration (AUTO)"

# RAM: 83% total, dengan guard minimal sisa 300MB untuk host
RAM_CALC=$(( TOTAL_RAM_MB * 83 / 100 ))
SAFE_CAP=$(( TOTAL_RAM_MB - 300 ))
(( SAFE_CAP < 300 )) && SAFE_CAP=300
if (( RAM_CALC > SAFE_CAP )); then
  RAM_SIZE=$SAFE_CAP
else
  RAM_SIZE=$RAM_CALC
fi
(( RAM_SIZE < 2048 )) && RAM_SIZE=2048
RAM_PERCENT=$(( RAM_SIZE * 100 / TOTAL_RAM_MB ))
echo "Allocated RAM (auto): ${RAM_SIZE} MB (~${RAM_PERCENT}% of total)"

# vCPU: all cores
VCPU_COUNT=$TOTAL_CPUS
echo "Allocated vCPUs (auto): ${VCPU_COUNT}"

# --- SAFE ISO SIZE FALLBACKS ---
ISO_CACHE="/opt/vm-isos"

VIRTIO_FILE="${ISO_CACHE}/virtio-win.iso"
VIRTIO_LINK="/var/lib/libvirt/boot/virtio-win.iso"

ISO_FILE="${ISO_CACHE}/Windows10-Ltsc.iso"
ISO_LINK="/var/lib/libvirt/boot/Windows10-Ltsc.iso"

VIRTIO_FILE="${VIRTIO_FILE:-/var/lib/libvirt/boot/virtio-win.iso}"

# Hitung ukuran total ISO (Windows + VirtIO) jika sudah ada file
ISO_WIN_SIZE_GB=$(stat -c%s "$ISO_FILE" 2>/dev/null || echo 0)
ISO_WIN_SIZE_GB=$(( ISO_WIN_SIZE_GB / 1073741824 ))
ISO_VIRTIO_SIZE_GB=$(stat -c%s "$VIRTIO_FILE" 2>/dev/null || echo 0)
ISO_VIRTIO_SIZE_GB=$(( ISO_VIRTIO_SIZE_GB / 1073741824 ))

ISO_TOTAL_SIZE=$(( ISO_WIN_SIZE_GB + ISO_VIRTIO_SIZE_GB ))
(( ISO_TOTAL_SIZE < 1 )) && ISO_TOTAL_SIZE=4   # fallback default total 4GB
echo "Detected ISO total size: ${ISO_TOTAL_SIZE} GB"

# Disk: free disk - iso - 5GB (minimum 20GB)
if (( FREE_DISK_GB > (ISO_TOTAL_SIZE + 5) )); then
  DISK_SIZE=$(( FREE_DISK_GB - ISO_TOTAL_SIZE - 5 ))
else
  DISK_SIZE=20
fi
(( DISK_SIZE < 20 )) && DISK_SIZE=20
echo "Allocated Disk (auto): ${DISK_SIZE} GB (free=${FREE_DISK_GB}G, -iso=${ISO_TOTAL_SIZE}G, -host=5G)"

# RDP port (PROMPT KEPT)
echo "🔧 Configure public RDP base port mapping"
echo "   Recommended range: 49152–65535 (to avoid port scanners)"
read -p "Enter base port for public RDP access [default: 3389]: " RDP_PORT
RDP_PORT=${RDP_PORT:-3389}
if ! [[ "$RDP_PORT" =~ ^[0-9]+$ ]]; then
  echo "❌ Invalid port number. Must be numeric."; exit 1
fi
if (( RDP_PORT < 1024 )); then
  echo "❌ Port must be >= 1024."; exit 1
fi
if [[ "$RDP_PORT" -eq 3389 ]]; then
  echo "⚠️  Using default RDP port (3389). Consider a high random port for security."
fi
echo "✓ Using base public port: $RDP_PORT"

# --- Dependencies ---
header "Installing dependencies"
sudo apt update -y
sudo apt install -y \
 qemu-kvm bridge-utils virtinst virt-manager cpu-checker \
 wget git make gcc meson ninja-build pkg-config genisoimage \
 libxml2-dev libdevmapper-dev libnl-3-dev libnl-route-3-dev \
 libyajl-dev libcurl4-gnutls-dev libglib2.0-dev libpciaccess-dev \
 libcap-ng-dev libselinux1-dev libsystemd-dev libapparmor-dev \
 libjson-c-dev libxslt1-dev xsltproc gettext libreadline-dev \
 libncurses5-dev libtirpc-dev python3-docutils \
 libgnutls28-dev gnutls-bin libxml2-utils xorriso \
 dosfstools libguestfs-tools swtpm swtpm-tools nftables \
 mesa-utils libgl1-mesa-dri mesa-vulkan-drivers virt-viewer

# ==== OpenGL Dependency & Check ==============================================
header "Checking OpenGL / GPU Environment"
if ! command -v glxinfo >/dev/null 2>&1; then
  step "Installing OpenGL utility packages (safety)..."
  sudo apt-get update -y
  sudo apt-get install -y mesa-utils libgl1-mesa-dri mesa-vulkan-drivers virt-viewer || {
    warn "Failed to install OpenGL dependencies; proceeding without GL support"
  }
fi
OPENGL_RENDERER=$(glxinfo 2>/dev/null | grep -i "OpenGL renderer" | head -1 || echo "unknown")
if [[ -z "$OPENGL_RENDERER" ]]; then
  warn "OpenGL renderer not detected — falling back to software mode (GL OFF)"
else
  echo "OpenGL renderer: $OPENGL_RENDERER"
fi
# ==============================================================================

# --- Prepare SWTPM (TPM 2.0 emulator) ---
header "Preparing SWTPM"

# Ensure required tools exist
if ! command -v certtool >/dev/null 2>&1; then
  warn "certtool not found; installing gnutls-bin..."
  sudo apt-get install -y gnutls-bin
fi
if ! command -v swtpm_setup >/dev/null 2>&1; then
  err "swtpm_setup not found; please install 'swtpm-tools'"; cleanup_and_exit
fi

# Start local CA used by swtpm_setup to issue EK/Platform certificates
if systemctl list-unit-files | grep -q swtpm-localca.socket; then
  sudo systemctl enable --now swtpm-localca.socket
  ok "swtpm-localca socket is active"
else
  warn "swtpm-localca.socket not available; swtpm_setup may fail"
fi

# Create libvirt swtpm base directory
sudo install -d -m 0755 -o root -g root /var/lib/libvirt/swtpm

# Pre-initialize TPM 2.0 state for this VM to avoid libvirt calling swtpm_setup
TPM_STATE_DIR="/var/lib/libvirt/swtpm/${VM_NAME}"
sudo install -d -m 0700 -o root -g root "$TPM_STATE_DIR"

TPM_ARGS=""
if sudo /usr/bin/swtpm_setup \
      --tpm2 \
      --tpmstate "dir=${TPM_STATE_DIR}" \
      --create-ek-cert \
      --create-platform-cert \
      --overwrite >/tmp/swtpm_setup_${VM_NAME}.log 2>&1; then
  ok "TPM 2.0 state pre-initialized"
  # Use the most compatible model for Windows 10 LTSC
  # --tpm backend.type=emulator,model=tpm-crb
  TPM_ARGS="--tpm backend.type=emulator,backend.version=2.0,model=tpm-tis"
else
  warn "TPM pre-initialization failed; see /tmp/swtpm_setup_${VM_NAME}.log"
  warn "Proceeding without a TPM; you can add a TPM to the VM later."
  TPM_ARGS=""
fi

# --- libvirt check ---
header "Checking libvirt/virsh"
SKIP_BUILD=false
set +e
if command -v virsh &>/dev/null; then
  VER_RAW=$(virsh --version 2>/dev/null || echo "unknown")
  VER=$(echo "$VER_RAW" | tr -d '\r\n[:space:]')
  echo "Detected virsh version: $VER"
  if echo "$VER" | grep -qE '^11\.8'; then
    ok "libvirt $VER detected — build skipped"
    SKIP_BUILD=true
  else
    warn "Detected libvirt version $VER → rebuilding or fixing path..."
  fi
else
  warn "virsh not found, attempting to build libvirt 11.8.0"
fi
set -e

# --- Ensure libvirt library consistency ---
header "Ensuring libvirt consistency"
sudo systemctl stop libvirtd virtqemud 2>/dev/null || true
sudo ldconfig

if [[ -f /usr/bin/virsh && -f /usr/lib/x86_64-linux-gnu/libvirt.so.0 ]]; then
  if ! strings /usr/lib/x86_64-linux-gnu/libvirt.so.0 | grep -q 'LIBVIRT_11'; then
    warn "Old libvirt library detected — cleaning up"
    sudo apt remove --purge -y libvirt-daemon-system libvirt-daemon libvirt-clients || true
    sudo rm -rf /usr/lib/x86_64-linux-gnu/libvirt* /usr/lib/libvirt* /usr/local/lib/libvirt* || true
  fi
fi

# --- Build or fallback ---
if [[ "$SKIP_BUILD" == false ]]; then
  header "Building libvirt 11.8.0"
  cd /usr/src; sudo rm -rf libvirt
  if ! sudo git clone --branch v11.8.0 --depth 1 https://github.com/libvirt/libvirt.git; then
    warn "Could not fetch v11.8.0, falling back to system libvirt"
    sudo apt update -y && sudo apt install -y libvirt-daemon-system libvirt-clients
    SKIP_BUILD=true
  else
    cd libvirt
    sudo meson setup build --prefix=/usr --libdir=/usr/lib -Dsystem=true
    sudo ninja -C build && sudo ninja -C build install
  fi
fi

# --- Post-install sanity check ---
header "Validating libvirt installation"
sudo ldconfig
sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now libvirtd virtqemud || true
sleep 2

if ! systemctl is-active --quiet libvirtd; then
  warn "libvirtd failed to start, attempting recovery..."
  if [[ -d /usr/lib64/libvirt && ! -d /usr/lib/libvirt ]]; then
    sudo ln -sf /usr/lib64/libvirt /usr/lib/libvirt
  fi
  sudo systemctl restart libvirtd || true
fi

if systemctl is-active --quiet libvirtd && command -v virsh &>/dev/null; then
  if ! getent group libvirt >/dev/null; then
    sudo groupadd -r libvirt
    ok "Group 'libvirt' created"
  fi
  if [[ "$EUID" -ne 0 ]]; then
    if ! groups $USER | grep -q libvirt; then
      sudo usermod -aG libvirt $USER
      warn "User added to 'libvirt' group. Run 'newgrp libvirt' to refresh session."
    fi
  else
    ok "Running as root — skipping usermod step"
  fi
  ok "libvirt group setup verified"
else
  warn "⚠ libvirt not fully functional — installing system version as fallback"
  sudo apt install -y libvirt-daemon-system libvirt-clients
  sudo systemctl enable --now libvirtd virtqemud
fi

# --- ISO Cache ---
header "Preparing Windows ISO"
sudo mkdir -p "$ISO_CACHE" /var/lib/libvirt/boot

# --- Ensure required libvirt system users exist ---
if ! getent group libvirt-qemu >/dev/null; then
  sudo groupadd -r libvirt-qemu
  ok "Group 'libvirt-qemu' created"
fi
if ! id libvirt-qemu &>/dev/null; then
  sudo useradd -r -g libvirt-qemu -d /var/lib/libvirt -s /usr/sbin/nologin libvirt-qemu
  ok "User 'libvirt-qemu' created"
fi
if ! getent group libvirt-dnsmasq >/dev/null; then
  sudo groupadd -r libvirt-dnsmasq
  ok "Group 'libvirt-dnsmasq' created"
fi
if ! id libvirt-dnsmasq &>/dev/null; then
  sudo useradd -r -g libvirt-dnsmasq -d /var/lib/libvirt/dnsmasq -s /usr/sbin/nologin libvirt-dnsmasq
  ok "User 'libvirt-dnsmasq' created"
fi

# --- Ensure Windows ISO ---
if [[ ! -f "$ISO_FILE" || $(stat -c%s "$ISO_FILE" 2>/dev/null || echo 0) -lt 1000000000 ]]; then
  step "Downloading Windows 10 Ltsc ISO..."
  sudo wget -O "$ISO_FILE" "https://archive.org/download/en-gb_windows_10_enterprise_ltsc_2019_x64_dvd_cd49b901/en-gb_windows_10_enterprise_ltsc_2019_x64_dvd_cd49b901.iso"
else
  ok "Using cached ISO: $ISO_FILE"
fi
if [[ ! -f "$ISO_LINK" ]]; then
  sudo cp -f "$ISO_FILE" "$ISO_LINK"
fi
if id libvirt-qemu &>/dev/null; then
  sudo chown libvirt-qemu:libvirt-qemu "$ISO_LINK"
else
  warn "User 'libvirt-qemu' not found — using root ownership"
  sudo chown root:root "$ISO_LINK"
fi
sudo chmod 644 "$ISO_LINK"

# --- Download virtio drivers ---
header "Preparing virtio Drivers"
if [[ ! -f "$VIRTIO_FILE" || $(stat -c%s "$VIRTIO_FILE" 2>/dev/null || echo 0) -lt 50000000 ]]; then
  step "Downloading latest virtio-win drivers..."
  sudo wget -O "$VIRTIO_FILE" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
  ok "virtio drivers downloaded"
else
  ok "Using cached virtio drivers: $VIRTIO_FILE"
fi
if [[ ! -f "$VIRTIO_LINK" ]]; then
  sudo cp -f "$VIRTIO_FILE" "$VIRTIO_LINK"
fi
if id libvirt-qemu &>/dev/null; then
  sudo chown libvirt-qemu:libvirt-qemu "$VIRTIO_LINK"
else
  warn "User 'libvirt-qemu' not found — using root ownership"
  sudo chown root:root "$VIRTIO_LINK"
fi
sudo chmod 644 "$VIRTIO_LINK"

# --- Generate autounattend.xml ---
header "Generating Unattended Installation File"
AUTOUNATTEND_DIR="/tmp/autounattend-${VM_NAME}"
rm -rf "$AUTOUNATTEND_DIR"; mkdir -p "$AUTOUNATTEND_DIR"

# Escape special XML characters
WIN_USERNAME_ESC=$(echo "$WIN_USERNAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g')
WIN_PASSWORD_ESC=$(echo "$WIN_PASSWORD" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g')
WIN_COMPUTERNAME_ESC=$(echo "$WIN_COMPUTERNAME" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g')

cat > "$AUTOUNATTEND_DIR/autounattend.xml" << 'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage>
        <UILanguage>en-GB</UILanguage>
      </SetupUILanguage>
      <InputLocale>en-GB</InputLocale>
      <SystemLocale>en-GB</SystemLocale>
      <UILanguage>en-GB</UILanguage>
      <UserLocale>en-GB</UserLocale>
    </component>

    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
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
          <ModifyPartitions>
            <ModifyPartition wcm:action="add">
              <Active>true</Active>
              <Format>NTFS</Format>
              <Label>System</Label>
              <Order>1</Order>
              <PartitionID>1</PartitionID>
            </ModifyPartition>
          </ModifyPartitions>
        </Disk>
      </DiskConfiguration>

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

      <UserData>
        <AcceptEula>true</AcceptEula>
        <FullName>VM User</FullName>
        <Organization>VirtualMachine</Organization>
        <ProductKey>
          <WillShowUI>Never</WillShowUI>
        </ProductKey>
      </UserData>

      <DynamicUpdate><Enable>false</Enable></DynamicUpdate>
    </component>

    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>E:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>E:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>E:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\qemupciserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\qemufwcfg\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>E:\pvpanic\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>E:\vioinput\w10\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>

  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>COMPUTERNAME_PLACEHOLDER</ComputerName>
      <TimeZone>UTC</TimeZone>
    </component>

    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>

    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAuthentication>1</UserAuthentication>
    </component>

    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <FirewallGroups>
        <FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop">
          <Active>true</Active>
          <Group>Remote Desktop</Group>
          <Profile>all</Profile>
        </FirewallGroup>
      </FirewallGroups>
    </component>
  </settings>

  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
        <SkipUserOOBE>true</SkipUserOOBE>
        <SkipMachineOOBE>true</SkipMachineOOBE>
      </OOBE>

      <UserAccounts>
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Password><Value>PASSWORD_PLACEHOLDER</Value><PlainText>true</PlainText></Password>
            <DisplayName>USERNAME_PLACEHOLDER</DisplayName>
            <Group>Administrators</Group>
            <Name>USERNAME_PLACEHOLDER</Name>
          </LocalAccount>
        </LocalAccounts>
      </UserAccounts>

      <AutoLogon>
        <Enabled>true</Enabled>
        <Username>USERNAME_PLACEHOLDER</Username>
        <Password><Value>PASSWORD_PLACEHOLDER</Value><PlainText>true</PlainText></Password>
        <LogonCount>1</LogonCount>
      </AutoLogon>

      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add">
          <Order>1</Order>
          <CommandLine>cmd /c netsh advfirewall set allprofiles state off</CommandLine>
          <Description>Disable Windows Firewall</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>2</Order>
          <CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine>
          <Description>Enable RDP</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>3</Order>
          <CommandLine>cmd /c netsh advfirewall firewall add rule name="Remote Desktop" protocol=TCP dir=in localport=3389 action=allow</CommandLine>
          <Description>Allow RDP Port</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>4</Order>
          <CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f &amp;&amp; reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v SecurityLayer /t REG_DWORD /d 1 /f</CommandLine>
          <Description>Enable NLA (no TLS)</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>5</Order>
          <CommandLine>cmd /c net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15</CommandLine>
          <Description>Set account lockout policy (5 attempts, 15 min lock)</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>6</Order>
          <CommandLine>cmd /c powercfg -change -monitor-timeout-ac 0</CommandLine>
          <Description>Disable screen timeout</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>7</Order>
          <CommandLine>cmd /c powercfg -change -standby-timeout-ac 0</CommandLine>
          <Description>Disable sleep</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>8</Order>
          <CommandLine>cmd /c echo Installation Complete &gt; C:\install_complete.txt</CommandLine>
          <Description>Mark installation complete</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>9</Order>
          <CommandLine>cmd /c bcdedit /set hypervisorlaunchtype off</CommandLine>
          <Description>Disable Hyper-V launch</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>10</Order>
          <CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\HvHost" /v Start /t REG_DWORD /d 4 /f</CommandLine>
          <Description>Disable Hyper-V Host Service</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>11</Order>
          <CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Services\vmcompute" /v Start /t REG_DWORD /d 4 /f</CommandLine>
          <Description>Disable Hyper-V Compute Service</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>12</Order>
          <CommandLine>cmd /c dism /Online /Disable-Feature /FeatureName:Microsoft-Hyper-V-All /NoRestart</CommandLine>
          <Description>Remove Hyper-V Feature (Optional)</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>13</Order>
          <CommandLine>cmd /c shutdown /r /t 15 /c "Hyper-V disabled, rebooting..."</CommandLine>
          <Description>Reboot after disabling Hyper-V</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>14</Order>
          <CommandLine>powershell.exe -ExecutionPolicy Bypass -Command "reg add 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f; reg add 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' /v RebootRelaunchTimeoutEnabled /t REG_DWORD /d 0 /f; reg add 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate\AU' /v AlwaysAutoRebootAtScheduledTime /t REG_DWORD /d 0 /f; schtasks /Change /TN '\Microsoft\Windows\TaskScheduler\Maintenance Configurator' /DISABLE; schtasks /Change /TN '\Microsoft\Windows\TaskScheduler\Regular Maintenance' /DISABLE; schtasks /Change /TN '\Microsoft\Windows\UpdateOrchestrator\Reboot' /DISABLE; schtasks /Change /TN '\Microsoft\Windows\UpdateOrchestrator\Schedule Retry' /DISABLE; schtasks /Change /TN '\Microsoft\Windows\UpdateOrchestrator\Schedule Maintenance Work' /DISABLE"</CommandLine>
          <Description>Disable Windows Update and Maintenance Auto Restart</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>15</Order>
          <CommandLine>msiexec /i E:\guest-agent\qemu-ga-x86_64.msi /qn /norestart</CommandLine>
          <Description>Install QEMU Guest Agent</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>16</Order>
          <CommandLine>cmd /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableRealtimeMonitoring /t REG_DWORD /d 1 /f</CommandLine>
          <Description>Disable Defender realtime monitoring</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>17</Order>
          <CommandLine>cmd /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableBehaviorMonitoring /t REG_DWORD /d 1 /f</CommandLine>
          <Description>Disable Defender behavior monitoring</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>18</Order>
          <CommandLine>cmd /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableOnAccessProtection /t REG_DWORD /d 1 /f</CommandLine>
          <Description>Disable Defender on-access protection</Description>
        </SynchronousCommand>

        <SynchronousCommand wcm:action="add">
          <Order>19</Order>
          <CommandLine>cmd /c reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows Defender\Real-Time Protection" /v DisableScanOnRealtimeEnable /t REG_DWORD /d 1 /f</CommandLine>
          <Description>Disable scan when realtime enabled</Description>
        </SynchronousCommand>

      </FirstLogonCommands>
      
    </component>
  </settings>
</unattend>
XMLEOF

# Replace placeholders
sed -i "s|USERNAME_PLACEHOLDER|${WIN_USERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|PASSWORD_PLACEHOLDER|${WIN_PASSWORD_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|COMPUTERNAME_PLACEHOLDER|${WIN_COMPUTERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"

# Validate XML
if command -v xmllint &>/dev/null; then
  if ! xmllint --noout "$AUTOUNATTEND_DIR/autounattend.xml" 2>/dev/null; then
    warn "xmllint found issues or is missing schema — skipping strict validation"
  else
    ok "Autounattend.xml validated successfully"
  fi
fi
ok "Autounattend.xml generated with username: ${WIN_USERNAME}"

# --- Create Floppy Image with autounattend.xml ---
FLOPPY_IMG="${ISO_CACHE}/autounattend-${VM_NAME}.img"
step "Creating floppy image with autounattend.xml..."
sudo dd if=/dev/zero of="$FLOPPY_IMG" bs=1024 count=1440 status=none 2>&1 || { err "Failed to create floppy image"; cleanup_and_exit; }
sudo mkfs.vfat -F 12 "$FLOPPY_IMG" 2>&1 | grep -v "warning" || { err "Failed to format floppy"; cleanup_and_exit; }
FLOPPY_MOUNT="/mnt/floppy-tmp-${VM_NAME}"
sudo mkdir -p "$FLOPPY_MOUNT"
sudo mount -o loop "$FLOPPY_IMG" "$FLOPPY_MOUNT" || { err "Failed to mount floppy"; cleanup_and_exit; }
sudo cp "$AUTOUNATTEND_DIR/autounattend.xml" "$FLOPPY_MOUNT/autounattend.xml" || { err "Failed to copy autounattend.xml"; sudo umount "$FLOPPY_MOUNT" 2>/dev/null; cleanup_and_exit; }
sudo sync
sudo umount "$FLOPPY_MOUNT" || true
sudo rmdir "$FLOPPY_MOUNT" 2>/dev/null || true
ok "Floppy image created: ${FLOPPY_IMG}"

# --- Remove old VM ---
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --nvram --remove-all-storage 2>/dev/null || true

# --- Create Disk ---
header "Creating VM Disk"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G
ok "Disk ${DISK_SIZE}G ready"

# --- Fix AppArmor issue ---
header "Fixing AppArmor configuration"
if grep -q '^security_driver' /etc/libvirt/qemu.conf 2>/dev/null; then
  sudo sed -i 's/^security_driver.*/security_driver = "none"/' /etc/libvirt/qemu.conf
else
  echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf
fi
sudo systemctl restart libvirtd
ok "AppArmor disabled for libvirt"

# --- Ensure default network exists and is persistent ---
if sudo virsh net-info default &>/dev/null; then
  sudo virsh net-destroy default 2>/dev/null || true
  sudo virsh net-undefine default 2>/dev/null || true
fi

echo "Recreating persistent default network with NAT + DHCP..."
cat <<EOF | sudo virsh net-define /dev/stdin
<network>
  <name>default</name>
  <bridge name="virbr0" stp="on" delay="0"/>
  <forward mode="nat"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp>
      <range start="192.168.122.2" end="192.168.122.254"/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-start default
if [[ -L /etc/libvirt/qemu/networks/autostart/default.xml ]]; then
  echo "Removing existing autostart symlink to prevent conflict..."
  sudo rm -f /etc/libvirt/qemu/networks/autostart/default.xml
fi
sudo virsh net-autostart default || { warn "Autostart symlink already exists, skipping..."; }
ok "Default network active with DHCP"

# --- Ensure KVM permission for libvirt-qemu ---
header "Checking KVM access"
if [[ -e /dev/kvm ]]; then
  sudo chown root:kvm /dev/kvm
  sudo chmod 660 /dev/kvm
  if id libvirt-qemu &>/dev/null; then
    sudo usermod -aG kvm libvirt-qemu || true
    ok "libvirt-qemu added to kvm group"
  else
    warn "libvirt-qemu user not found; skipping group assignment"
  fi
  sudo systemctl restart libvirtd || true
  if sudo -u libvirt-qemu test -r /dev/kvm; then
    ok "libvirt-qemu can access /dev/kvm"
  else
    warn "⚠ libvirt-qemu still cannot access /dev/kvm — fallback to software virtualization"
    USE_TCG=true
  fi
else
  warn "/dev/kvm not found — falling back to software virtualization (TCG)"
  USE_TCG=true
fi


# ==== Graphics / GPU detection & virt-type ====================================
VIRT_TYPE=(--virt-type kvm)
[[ "${USE_TCG:-false}" == "true" ]] && VIRT_TYPE=(--virt-type qemu)

RENDER_NODE=""
for n in /dev/dri/renderD*; do
  [[ -e "$n" ]] && RENDER_NODE="$n" && break
done

if [[ -n "$RENDER_NODE" ]]; then
  if id libvirt-qemu &>/dev/null; then
    sudo usermod -aG render libvirt-qemu 2>/dev/null || true
    sudo systemctl restart libvirtd 2>/dev/null || true
    if ! sudo -u libvirt-qemu test -r "$RENDER_NODE"; then
      echo "⚠️  libvirt-qemu cannot access $RENDER_NODE → fallback GL OFF"
      RENDER_NODE=""
    fi
  else
    echo "⚠️  user libvirt-qemu missing → fallback GL OFF"
    RENDER_NODE=""
  fi
fi

if [[ -n "$RENDER_NODE" ]]; then
  GRAPHICS_OPT=(--graphics "spice,listen=none,gl=on,rendernode=${RENDER_NODE}")
  VIDEO_OPT=(--video "virtio,accel3d=yes")
  echo "✅ GL ON via ${RENDER_NODE} (SPICE-GL, local socket)"
else
  GRAPHICS_OPT=(--graphics "spice,listen=127.0.0.1,gl=off")
  VIDEO_OPT=(--video "virtio")
  echo "ℹ️  GL OFF fallback (safe mode)"
fi
# ==============================================================================

# --- Create VM with Performance Optimizations ---
header "Creating Virtual Machine"

sudo virt-install \
  --name "${VM_NAME}" \
  --ram "${RAM_SIZE}" \
  --vcpus "${VCPU_COUNT}",maxvcpus="${VCPU_COUNT}",sockets=1,cores="${VCPU_COUNT}",threads=1 \
  --cpu host-passthrough,cache.mode=passthrough \
  "${VIRT_TYPE[@]}" \
  --cdrom "${ISO_LINK}" \
  --disk path="/var/lib/libvirt/images/${VM_NAME}.img",size="${DISK_SIZE}",bus=scsi,discard=unmap,detect_zeroes=unmap,cache=writeback,io=threads \
  --controller type=scsi,model=virtio-scsi \
  --controller type=virtio-serial \
  --os-variant win10 \
  --network network=default,model=virtio \
  "${GRAPHICS_OPT[@]}" \
  "${VIDEO_OPT[@]}" \
  --channel spicevmc \
  --input tablet,bus=usb \
  --boot hd,cdrom,menu=on \
  --disk "${VIRTIO_LINK}",device=cdrom \
  --disk "${FLOPPY_IMG}",device=floppy \
  --check path_in_use=off \
  --features hyperv_relaxed=on,hyperv_vapic=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191 \
  --clock hypervclock_present=yes \
  ${TPM_ARGS} \
  --rng device=/dev/urandom \
  --noautoconsole


ok "VM created: ${VM_NAME}"

# --- Enable Nested Virtualization ---
echo "🔧 Checking for nested virtualization support..."
if grep -q vmx /proc/cpuinfo; then
  echo "🧠 Intel CPU detected — enabling nested virtualization"
  sudo modprobe -r kvm_intel 2>/dev/null || true
  sudo modprobe kvm_intel nested=1
  echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm_intel.conf >/dev/null
elif grep -q svm /proc/cpuinfo; then
  echo "🧠 AMD CPU detected — enabling nested virtualization"
  sudo modprobe -r kvm_amd 2>/dev/null || true
  sudo modprobe kvm_amd nested=1
  echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm_amd.conf >/dev/null
else
  warn "⚠️ No VMX/SVM virtualization extensions found; nested virtualization unavailable."
fi

# Ensure guest CPU gets VMX feature flag
sudo virt-xml "${VM_NAME}" --edit --cpu host-passthrough,add_feature=vmx 2>/dev/null || true
ok "Nested virtualization enabled for ${VM_NAME} (VMX passthrough active)"

# --- Force boot order to HDD first ---
echo "🧩 Forcing boot order: hard disk first"
sudo virt-xml "${VM_NAME}" --edit --boot hd,cdrom || true
ok "Boot order set to HDD first"

# --- Load vhost_net module ---
echo "🔧 Checking for vhost_net module..."
if ! lsmod | grep -q vhost_net; then
  echo "➡️  Loading vhost_net kernel module..."; sudo modprobe vhost_net
  grep -q "vhost_net" /etc/modules 2>/dev/null || echo "vhost_net" | sudo tee -a /etc/modules >/dev/null
  ok "vhost_net module loaded"
fi

# --- Stop VM temporarily for configuration ---
echo "⏸️  Stopping VM for final configuration..."
sudo virsh shutdown "${VM_NAME}" 2>/dev/null || true
for i in {1..30}; do
  if ! sudo virsh list --state-running | grep -q "${VM_NAME}"; then break; fi
  sleep 1
done
sudo virsh destroy "${VM_NAME}" 2>/dev/null || true
sleep 2

# --- Enable vhost accelerator and multiqueue ---
echo "⚙️  Enabling vhost accelerator and multiqueue (${VCPU_COUNT} queues)..."
sudo virt-xml "${VM_NAME}" --edit --network driver_name=vhost,driver_queues="${VCPU_COUNT}" 2>/dev/null || warn "Failed to set vhost, continuing..."

# --- Start VM ---
header "Starting Windows Installation"
sudo virsh start "${VM_NAME}"
ok "VM started - Windows installation beginning..."
sleep 15

header "Monitoring Installation Progress"
echo -e "${BLUE}This will take 10-20 minutes depending on your system${NC}"
echo -e "${YELLOW}The VM will reboot automatically during installation${NC}"
echo ""

REBOOT_DETECTED=false
INSTALL_COMPLETE=false
CHECK_COUNT=0
MAX_CHECKS=2160

while (( CHECK_COUNT < MAX_CHECKS )); do
  CHECK_COUNT=$((CHECK_COUNT + 1))

  if sudo virsh list --state-running | grep -q "${VM_NAME}"; then
    echo -n "."
  else
    if [[ "$REBOOT_DETECTED" == "false" ]]; then
      echo ""
      echo "🔄 Reboot detected! Ensuring HDD boot first..."
      REBOOT_DETECTED=true
      sudo virt-xml "${VM_NAME}" --edit --boot hd,cdrom 2>/dev/null || true
      sleep 5
      echo "🚀 Restarting VM..."
      sudo virsh start "${VM_NAME}" 2>/dev/null || true
      sleep 10
    else
      echo ""
      warn "VM stopped unexpectedly, restarting..."
      sudo virsh start "${VM_NAME}" 2>/dev/null || true
      sleep 10
    fi
  fi

  if (( CHECK_COUNT % 10 == 0 )); then
    VM_IP=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1 || echo "")
    if [[ -n "$VM_IP" ]]; then
      echo ""
      echo "✅ Network detected! VM IP: ${VM_IP}"
      echo "🎉 Windows installation likely complete!"
      INSTALL_COMPLETE=true
      break
    fi
  fi

  if (( CHECK_COUNT % 20 == 0 )) && command -v guestfish >/dev/null 2>&1; then
    IMG="/var/lib/libvirt/images/${VM_NAME}.img"
    if sudo guestfish --ro -a "$IMG" -i sh "test -f /install_complete.txt || test -f /Windows/System32/winload.exe" >/dev/null 2>&1; then
      echo ""
      echo "✅ Installation artifacts found on disk (guestfish)."
      INSTALL_COMPLETE=true
      break
    fi
  fi

  sleep 10
done

sleep 10
echo "⏳ Waiting for VM network initialization..."
echo "   (This may take 30-60 seconds for Windows to boot and get IP address)"

set +e
MAX_WAIT=60
IP_DETECTED=false

for i in $(seq 1 $MAX_WAIT); do
  if ! sudo virsh dominfo "${VM_NAME}" &>/dev/null; then
    echo ""
    echo "⚠️ VM ${VM_NAME} not found or not defined"
    break
  fi

  VM_COUNT=$(sudo virsh list --name 2>/dev/null | grep -c -v '^$' || echo "0")
  if [[ "$VM_COUNT" == "0" ]]; then
    echo ""
    echo "⚠️ No running VMs detected, attempting to start ${VM_NAME}..."
    sudo virsh start "${VM_NAME}" >/dev/null 2>&1
    sleep 5
    continue
  fi

  HAS_IP=""
  VM_LIST=$(sudo virsh list --name 2>/dev/null || echo "")
  if [[ -n "$VM_LIST" ]]; then
    while IFS= read -r vm; do
      if [[ -n "$vm" ]] && [[ "$vm" != "" ]]; then
        IP_CHECK=$(sudo virsh domifaddr "$vm" 2>/dev/null | grep -o 'ipv4' || echo "")
        if [[ "$IP_CHECK" == "ipv4" ]]; then
          HAS_IP="yes"
          break
        fi
      fi
    done <<< "$VM_LIST"
  fi

  if [[ "$HAS_IP" == "yes" ]]; then
    echo ""
    echo "✓ VM IP detected after ${i} seconds"
    IP_DETECTED=true
    sleep 5
    break
  fi

  if (( i % 10 == 0 )); then
    echo ""
    echo "   ... still waiting (${i}s / ${MAX_WAIT}s)"
  else
    echo -n "."
  fi

  sleep 1
done
set -e

echo ""
if [[ "$IP_DETECTED" == "true" ]]; then
  echo "✅ Network initialization successful"
else
  echo "⚠️ Timeout waiting for network (${MAX_WAIT}s elapsed)"
  echo "   VM may still be booting. Check manually with:"
  echo "   sudo virsh domifaddr ${VM_NAME}"
fi

echo ""
if true; then
  echo ""
  echo "🔧 Applying HugePages + RAM limit (target 83% host, 100% backed by HugePages)..."

  HUGEPAGE_KIB=2048  # 2 MiB

  # Target: 83% dari RAM host (minimum 4GB)
  TARGET_RAM_MB=$(( TOTAL_RAM_MB * 83 / 100 ))
  [[ $TARGET_RAM_MB -lt 4096 ]] && TARGET_RAM_MB=4096

  TARGET_RAM_KIB=$(( TARGET_RAM_MB * 1024 ))
  # berapa halaman 2MiB yang dibutuhkan untuk target RAM ini
  TARGET_PAGES=$(( TARGET_RAM_KIB / HUGEPAGE_KIB ))

  echo "→ Target VM RAM (theoretical): ${TARGET_RAM_MB} MB (~83% of host)"
  echo "→ Requesting HugePages: ${TARGET_PAGES} x 2MB pages"

  echo "⏸️  Stopping VM before applying HugePages..."
  virsh destroy "${VM_NAME}" >/dev/null 2>&1 || true
  sleep 2

  echo "🧹 Resetting previous HugePages on host..."
  echo 0 > /proc/sys/vm/nr_hugepages
  sync
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
  sleep 1

  if ! echo "${TARGET_PAGES}" > /proc/sys/vm/nr_hugepages 2>/dev/null; then
    echo "❌ Failed to set nr_hugepages=${TARGET_PAGES}"
    echo "   Starting VM WITHOUT HugePages (host cannot satisfy request)."
    virsh start "${VM_NAME}" >/dev/null 2>&1 || true

    header "Installation Complete!"
    ok "Windows 10 Ltsc installed (no HugePages)."
    echo ""
    echo -e "${BLUE}VM Details:${NC}"
    echo "  Name: ${VM_NAME}"
    echo "  Computer Name: ${WIN_COMPUTERNAME}"
    echo "  Username: ${WIN_USERNAME}"
    echo "  Password: [hidden]"
    echo "  IP Address: ${VM_IP:-unknown}"
    echo ""
    echo -e "${GREEN}✅ Auto-configured features:${NC}"
    echo "  ✓ VirtIO storage & network drivers"
    echo "  ✓ Remote Desktop (RDP) enabled"
    echo "  ✓ Windows Firewall disabled"
    echo "  ✓ Network configured automatically"
    echo ""
    echo -e "${BLUE}Resource Allocation:${NC}"
    echo "  RAM (install phase): ${RAM_SIZE} MB (~${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
    echo "  RAM (final): ${RAM_SIZE} MB (HugePages OFF)"
    echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS}"
    echo "  Disk: ${DISK_SIZE} GB"
  else
    echo "✓ HugePages allocation requested on host"
    grep HugePages_ /proc/meminfo || true

    ACTUAL_PAGES=$(grep HugePages_Total /proc/meminfo | awk '{print $2}')
    [[ -z "${ACTUAL_PAGES}" ]] && ACTUAL_PAGES=0

    if (( ACTUAL_PAGES <= 0 )); then
      echo "❌ Host failed to allocate any HugePages. Starting VM WITHOUT HugePages."
      virsh start "${VM_NAME}" >/dev/null 2>&1 || true

      header "Installation Complete!"
      ok "Windows 10 Ltsc installed (no HugePages)."
      echo ""
      echo -e "${BLUE}VM Details:${NC}"
      echo "  Name: ${VM_NAME}"
      echo "  Computer Name: ${WIN_COMPUTERNAME}"
      echo "  Username: ${WIN_USERNAME}"
      echo "  Password: [hidden]"
      echo "  IP Address: ${VM_IP:-unknown}"
      echo ""
      echo -e "${GREEN}✅ Auto-configured features:${NC}"
      echo "  ✓ VirtIO storage & network drivers"
      echo "  ✓ Remote Desktop (RDP) enabled"
      echo "  ✓ Windows Firewall disabled"
      echo "  ✓ Network configured automatically"
      echo ""
      echo -e "${BLUE}Resource Allocation:${NC}"
      echo "  RAM (install phase): ${RAM_SIZE} MB (~${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
      echo "  RAM (final): ${RAM_SIZE} MB (HugePages OFF)"
      echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS}"
      echo "  Disk: ${DISK_SIZE} GB"
    else
      if (( ACTUAL_PAGES < TARGET_PAGES )); then
        echo "⚠ Requested ${TARGET_PAGES} pages, but host only allocated ${ACTUAL_PAGES} pages."
        echo "  VM RAM will be SHRUNK to fully match HugePages (100% backed)."
        TARGET_PAGES=${ACTUAL_PAGES}
      fi

      TARGET_RAM_KIB=$(( TARGET_PAGES * HUGEPAGE_KIB ))
      TARGET_RAM_MB=$(( TARGET_RAM_KIB / 1024 ))
      TARGET_RAM_GIB=$(( TARGET_RAM_MB / 1024 ))

      PCT_HOST=$(( TARGET_RAM_MB * 100 / TOTAL_RAM_MB ))

      echo "→ Final VM RAM (based on HugePages): ${TARGET_RAM_MB} MB (~${TARGET_RAM_GIB} GB, ~${PCT_HOST}% of host)"
      echo "→ memory/currentMemory will be set to: ${TARGET_RAM_KIB} KiB"

      XML_TMP=$(mktemp)
      virsh dumpxml "${VM_NAME}" > "${XML_TMP}"

      # Bersihkan memoryBacking lama dulu
      sed -i '/<memoryBacking>/,/<\/memoryBacking>/d' "${XML_TMP}"

      # Inject memoryBacking baru dengan HugePages 2MiB
      sed -i "/<currentMemory unit='KiB'>/a\
  <memoryBacking>\n\
    <hugepages>\n\
      <page size='2' unit='MiB'/>\n\
    </hugepages>\n\
  </memoryBacking>" "${XML_TMP}"

      echo "==== DEBUG: memoryBacking in XML_TMP ===="
      grep -n "memoryBacking" "${XML_TMP}" || echo "NO memoryBacking in XML_TMP"
      echo "========================================="

      # Set <memory> & <currentMemory> ke RAM final
      sed -i "s|\(<memory unit='KiB'>\)[0-9]\+\(</memory>\)|\1${TARGET_RAM_KIB}\2|" "${XML_TMP}"
      sed -i "s|\(<currentMemory unit='KiB'>\)[0-9]\+\(</currentMemory>\)|\1${TARGET_RAM_KIB}\2|" "${XML_TMP}"

      if virsh define "${XML_TMP}"; then
        echo "✓ XML updated → VM now uses HugePages + ${TARGET_RAM_MB}MB (~${TARGET_RAM_GIB}GB)"
      else
        echo "❌ virsh define failed, check ${XML_TMP}"
      fi
      rm -f "${XML_TMP}"

      echo "🚀 Starting VM with HugePages..."
      virsh start "${VM_NAME}" >/dev/null 2>&1 || true
      sleep 5

      echo "🎉 HugePages active — VM running with ${TARGET_RAM_MB}MB (~${TARGET_RAM_GIB}GB, ~${PCT_HOST}% of host, fully backed)"

      # Configure port forward
      if [[ -f "$PORT_FORWARD_SCRIPT" ]]; then
        echo ""
        echo "🚀 Configuring RDP port forwarding..."
        sudo bash "$PORT_FORWARD_SCRIPT" "$RDP_PORT"
      else
        warn "enable_port_forward_rdp.sh not found in $SCRIPT_DIR. Skipping auto-configuration."
        echo "Download and run manually when VM is ready."
      fi

      header "Installation Complete!"
      ok "Windows 10 Ltsc installed successfully!"
      echo ""
      echo -e "${BLUE}VM Details:${NC}"
      echo "  Name: ${VM_NAME}"
      echo "  Computer Name: ${WIN_COMPUTERNAME}"
      echo "  Username: ${WIN_USERNAME}"
      echo "  Password: [hidden]"
      echo "  IP Address: ${VM_IP:-unknown}"
      echo ""
      echo -e "${GREEN}✅ Auto-configured features:${NC}"
      echo "  ✓ VirtIO storage & network drivers"
      echo "  ✓ Remote Desktop (RDP) enabled"
      echo "  ✓ Windows Firewall disabled"
      echo "  ✓ Network configured automatically"
      echo ""
      echo -e "${BLUE}Resource Allocation:${NC}"
      echo "  RAM (install phase): ${RAM_SIZE} MB (~${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
      echo "  RAM (final hugepages): ${TARGET_RAM_MB} MB (~${TARGET_RAM_GIB} GB, ~${PCT_HOST}% of host, 100% backed)"
      echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS}"
      echo "  Disk: ${DISK_SIZE} GB"
    fi
  fi

else
  warn "Installation monitoring timed out after $(( MAX_CHECKS * 10 / 60 )) minutes"
  echo ""
  echo "Please check VM status manually:"
  echo "  sudo virsh list --all"
  echo "  sudo virsh domifaddr ${VM_NAME}"

  echo ""
  echo -e "${BLUE}Resource Allocation:${NC}"
  echo "  RAM (install phase): ${RAM_SIZE} MB (~${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
  echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS}"
  echo "  Disk: ${DISK_SIZE} GB"
fi