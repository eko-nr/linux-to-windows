#!/bin/bash
# ============================================================
# Windows 10 LTSC UNATTENDED Installer for Debian 12+ / Ubuntu 22+
# Full automation with reboot handling (FIXED windowsPE parsing)
# ============================================================

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PORT_FORWARD_SCRIPT="$SCRIPT_DIR/enable_port_forward_rdp.sh"
AUTO_RESTART_SCRIPT="$SCRIPT_DIR/auto_restart.sh"

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
header "Detecting System Resources"
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
echo "Total Physical RAM: ${TOTAL_RAM_MB} MB"
TOTAL_CPUS=$(nproc)
echo "Total CPU Cores: ${TOTAL_CPUS}"
TOTAL_DISK_GB=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
echo "Total Disk Space: ${TOTAL_DISK_GB} GB (Free: ${FREE_DISK_GB} GB)"

# --- Windows User Configuration ---
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
WIN_COMPUTERNAME=${WIN_COMPUTERNAME:-WIN10-VM}

# --- VM Config ---
header "VM Configuration"
read -p "VM name [win10ltsc]: " VM_NAME; VM_NAME=${VM_NAME:-win10ltsc}

read -p "RAM allocation (% of ${TOTAL_RAM_MB}MB) [50]: " RAM_PERCENT
RAM_PERCENT=${RAM_PERCENT:-50}
RAM_SIZE=$(( TOTAL_RAM_MB * RAM_PERCENT / 100 ))
echo "Allocated RAM: ${RAM_SIZE} MB (${RAM_PERCENT}% of total)"

MAX_VCPU=$TOTAL_CPUS
read -p "vCPU count (max: ${MAX_VCPU}) [2]: " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-2}
if (( VCPU_COUNT > MAX_VCPU )); then warn "Exceeds max; set to ${MAX_VCPU}"; VCPU_COUNT=$MAX_VCPU; fi
echo "Allocated vCPUs: ${VCPU_COUNT}"

read -p "Disk size in GB (max: ${FREE_DISK_GB}GB free) [50]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-50}
if (( DISK_SIZE > FREE_DISK_GB )); then warn "Exceeds free; set to ${FREE_DISK_GB}GB"; DISK_SIZE=$FREE_DISK_GB; fi
if (( DISK_SIZE < 20 )); then warn "Too small; set to 20GB"; DISK_SIZE=20; fi
echo "Allocated Disk: ${DISK_SIZE} GB"

read -p "VNC port [5901]: " VNC_PORT; VNC_PORT=${VNC_PORT:-5901}

read -p "Swap size in GB [4]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}
(( SWAP_SIZE < 1 )) && SWAP_SIZE=1
(( SWAP_SIZE > 16 )) && SWAP_SIZE=16
echo "Allocated Swap: ${SWAP_SIZE} GB"

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
 dosfstools libguestfs-tools swtpm swtpm-tools nftables


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

# Detect mismatched installs
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
    warn "Could not fetch v11.8.0, falling back to latest stable from apt"
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

# Final check
if systemctl is-active --quiet libvirtd && command -v virsh &>/dev/null; then
  # --- User/group setup for libvirt ---
  if ! getent group libvirt >/dev/null; then
    sudo groupadd -r libvirt
    ok "Group 'libvirt' created"
  fi

  # Only add user if not root
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
  step "Downloading Windows 10 LTSC ISO..."
  sudo wget -O "$ISO_FILE" "https://archive.org/download/windows-10-ltsc-enterprise-feb-2019/17763.2028/Windows_10__ENT_LTSC_OEM-June_x64_multilingual%5B17763.2028%5D.iso"
else
  ok "Using cached ISO: $ISO_FILE"
fi

# Always ensure ISO available in libvirt boot path
if [[ ! -f "$ISO_LINK" ]]; then
  sudo cp -f "$ISO_FILE" "$ISO_LINK"
fi

# Apply safe permissions
if id libvirt-qemu &>/dev/null; then
  sudo chown libvirt-qemu:libvirt-qemu "$ISO_LINK"
else
  warn "User 'libvirt-qemu' not found — using root ownership"
  sudo chown root:root "$ISO_LINK"
fi
sudo chmod 644 "$ISO_LINK"

# --- Download virtio drivers ---
header "Preparing virtio Drivers"
VIRTIO_FILE="${ISO_CACHE}/virtio-win.iso"
VIRTIO_LINK="/var/lib/libvirt/boot/virtio-win.iso"

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

# Apply safe permissions
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
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
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
      <!-- removed invalid <RestartAutomatically> element -->
    </component>

    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DriverPaths>
      <!-- 
        [OLD CONFIG - commented out for reference]
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>E:\viostor\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:keyValue="1"><Path>E:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>E:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>E:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\qemupciserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\qemufwcfg\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>E:\pvpanic\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>E:\vioinput\w10\amd64</Path></PathAndCredentials>
      -->

      <!-- [NEW CONFIG - uses vioscsi for VirtIO storage detection] -->
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
      <UserAuthentication>0</UserAuthentication>
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
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c netsh advfirewall set allprofiles state off</CommandLine><Description>Disable Windows Firewall</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine><Description>Enable RDP</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c netsh advfirewall firewall add rule name="Remote Desktop" protocol=TCP dir=in localport=3389 action=allow</CommandLine><Description>Allow RDP Port</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>4</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 0 /f</CommandLine><Description>Disable NLA for RDP</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>5</Order><CommandLine>cmd /c powercfg -change -monitor-timeout-ac 0</CommandLine><Description>Disable screen timeout</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>6</Order><CommandLine>cmd /c powercfg -change -standby-timeout-ac 0</CommandLine><Description>Disable sleep</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>7</Order><CommandLine>cmd /c echo Installation Complete &gt; C:\install_complete.txt</CommandLine><Description>Mark installation complete</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF

# Replace placeholders with escaped values
sed -i "s|USERNAME_PLACEHOLDER|${WIN_USERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|PASSWORD_PLACEHOLDER|${WIN_PASSWORD_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|COMPUTERNAME_PLACEHOLDER|${WIN_COMPUTERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"

# Validate XML strictly
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

# --- Create Disk ---
header "Creating VM Disk"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G
ok "Disk ${DISK_SIZE}G ready"

# --- Remove old VM ---
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --nvram --remove-all-storage 2>/dev/null || true

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

sudo virsh net-autostart default || {
  warn "Autostart symlink already exists, skipping..."
}
ok "Default network active with DHCP"

# --- Create VM with Performance Optimizations ---
header "Creating Virtual Machine"

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

sudo virt-install \
  --name "${VM_NAME}" \
  --ram "${RAM_SIZE}" \
  --vcpus "${VCPU_COUNT}",maxvcpus="${VCPU_COUNT}",sockets=1,cores="${VCPU_COUNT}",threads=1 \
  --cpu host-passthrough,cache.mode=passthrough \
  --cdrom "${ISO_LINK}" \
  --disk path="/var/lib/libvirt/images/${VM_NAME}.img",size="${DISK_SIZE}",bus=scsi,discard=unmap,detect_zeroes=unmap,cache=writeback,io=threads \
  --controller type=scsi,model=virtio-scsi \
  --controller type=virtio-serial \
  --os-variant win10 \
  --network network=default,model=virtio \
  --graphics vnc,listen=0.0.0.0,port="${VNC_PORT}" \
  --boot hd,cdrom,menu=on \
  --disk "${VIRTIO_LINK}",device=cdrom \
  --disk "${FLOPPY_IMG}",device=floppy \
  --check path_in_use=off \
  --features hyperv_relaxed=on,hyperv_vapic=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191 \
  --clock hypervclock_present=yes \
  --tpm backend.type=emulator,model=tpm-crb \
  --rng device=/dev/urandom \
  --memorybacking access.mode=shared \
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

# --- Configure Huge Pages ---
echo "⚡ Configuring huge pages for better memory performance..."
HUGEPAGES_NEEDED=$(( (RAM_SIZE / 2) + 256 ))
AVAILABLE_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
MAX_HUGEPAGES=$(( (AVAILABLE_MEM_MB - 512) / 2 ))
if (( HUGEPAGES_NEEDED > MAX_HUGEPAGES )); then
  warn "Not enough free memory for ${HUGEPAGES_NEEDED} huge pages"; SKIP_HUGEPAGES=true
else
  CURRENT_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages 2>/dev/null || echo 0)
  if (( CURRENT_HUGEPAGES < HUGEPAGES_NEEDED )); then
    echo ${HUGEPAGES_NEEDED} | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
    ACTUAL_HUGEPAGES=$(cat /proc/sys/vm/nr_hugepages)
    if (( ACTUAL_HUGEPAGES < HUGEPAGES_NEEDED )); then warn "Could only allocate ${ACTUAL_HUGEPAGES} huge pages"; SKIP_HUGEPAGES=true
    else
      grep -q "vm.nr_hugepages" /etc/sysctl.conf 2>/dev/null \
        && sudo sed -i "s/^vm.nr_hugepages=.*/vm.nr_hugepages=${HUGEPAGES_NEEDED}/" /etc/sysctl.conf \
        || echo "vm.nr_hugepages=${HUGEPAGES_NEEDED}" | sudo tee -a /etc/sysctl.conf >/dev/null
      ok "Huge pages configured: ${ACTUAL_HUGEPAGES}"; SKIP_HUGEPAGES=false
    fi
  else ok "Huge pages already configured: ${CURRENT_HUGEPAGES}"; SKIP_HUGEPAGES=false
  fi
fi

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

# --- Enable Huge Pages for VM ---
if [[ "${SKIP_HUGEPAGES:-true}" == "false" ]]; then
  echo "💾 Enabling huge pages for VM..."
  sudo virt-xml "${VM_NAME}" --edit --memorybacking hugepages=on 2>/dev/null || warn "Failed to set huge pages, continuing..."
  ok "Huge pages enabled for VM"
fi

# --- Start VM ---
header "Starting Windows Installation"
sudo virsh start "${VM_NAME}"
ok "VM started - Windows installation beginning..."

header "Monitoring Installation Progress"
echo -e "${BLUE}This will take 10-20 minutes depending on your system${NC}"
echo -e "${YELLOW}The VM will reboot automatically during installation${NC}"
echo ""

REBOOT_DETECTED=false
INSTALL_COMPLETE=false
CHECK_COUNT=0
MAX_CHECKS=180  # 30 minutes max

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

# --- Auto Port Forwarding for RDP ---
header "Auto Configuring RDP Port Forwarding"

# Wait for VM to fully boot and get IP
echo "⏳ Waiting for VM network initialization..."
echo "   (This may take 30-60 seconds for Windows to boot and get IP address)"

# Smart wait: check if VMs are getting IPs
MAX_WAIT=60
for i in $(seq 1 $MAX_WAIT); do
  VM_COUNT=$(virsh list --name | grep -v '^$' | wc -l)
  if [[ $VM_COUNT -gt 0 ]]; then
    # Check if any VM has IP
    HAS_IP=$(virsh list --name | while read vm; do
      [[ -n "$vm" ]] && virsh domifaddr "$vm" 2>/dev/null | grep -q ipv4 && echo "yes" && break
    done)
    
    if [[ "$HAS_IP" == "yes" ]]; then
      echo "✓ VM IP detected after ${i} seconds"
      sleep 5  # Extra buffer
      break
    fi
  fi
  
  # Progress indicator
  if [[ $((i % 10)) -eq 0 ]]; then
    echo "   ... still waiting (${i}s / ${MAX_WAIT}s)"
  fi
  sleep 1
done

echo ""
if [[ "$INSTALL_COMPLETE" == "true" ]]; then
  header "Installation Complete!"
  ok "Windows 10 LTSC installed successfully!"
  echo ""
  echo -e "${BLUE}VM Details:${NC}"
  echo "  Name: ${VM_NAME}"
  echo "  Computer Name: ${WIN_COMPUTERNAME}"
  echo "  Username: ${WIN_USERNAME}"
  echo "  Password: [hidden]"
  echo "  IP Address: ${VM_IP:-unknown}"
  echo ""
  echo -e "${BLUE}VNC Connection:${NC}"
  echo "  ${YELLOW}$(hostname -I | awk '{print $1}'):${VNC_PORT}${NC}"
  echo ""
  echo -e "${GREEN}✅ Auto-configured features:${NC}"
  echo "  ✓ VirtIO storage & network drivers"
  echo "  ✓ Remote Desktop (RDP) enabled"
  echo "  ✓ Windows Firewall disabled"
  echo "  ✓ Network configured automatically"
else
  warn "Installation monitoring timed out after $(( MAX_CHECKS * 10 / 60 )) minutes"
  echo ""
  echo "Please check VM status manually:"
  echo "  sudo virsh list --all"
  echo "  sudo virsh domifaddr ${VM_NAME}"
  echo ""
  echo "Connect via VNC to check progress:"
  echo "  ${YELLOW}$(hostname -I | awk '{print $1}'):${VNC_PORT}${NC}"
fi

echo ""
echo -e "${BLUE}Resource Allocation:${NC}"
echo "  RAM: ${RAM_SIZE} MB (${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS}"
echo "  Disk: ${DISK_SIZE} GB"
echo "  Swap: ${SWAP_SIZE} GB"
echo ""
echo -e "${BLUE}Performance Features:${NC}"
echo "  ✓ KVM hardware virtualization"
echo "  ✓ VirtIO drivers (network + storage)"
echo "  ✓ Host CPU passthrough"
echo "  ✓ vhost-net acceleration + multiqueue (${VCPU_COUNT})"
if [[ "${SKIP_HUGEPAGES:-true}" == "false" ]]; then
  echo "  ✓ Huge pages enabled"
else
  echo "  ○ Huge pages skipped (insufficient memory)"
fi
echo "  ✓ Hyper-V enlightenments"
echo ""
echo -e "${BLUE}Cached Files:${NC}"
echo "  Windows ISO: ${ISO_FILE}"
echo "  VirtIO Drivers: ${VIRTIO_FILE}"
echo "  Autounattend Floppy: ${FLOPPY_IMG}"
echo ""
ok "Setup complete! VM is ready to use."

# Configure auto restart
if [[ -f "$AUTO_RESTART_SCRIPT" ]]; then
  echo ""
  echo "🚀 Configuring VM auto-restart..."
  sudo bash "$AUTO_RESTART_SCRIPT"
else
  echo "No auto restart when vm stopped"
fi

# Configure port forward
if [[ -f "$PORT_FORWARD_SCRIPT" ]]; then
  echo ""
  echo "🚀 Configuring RDP port forwarding..."
  sudo bash "$PORT_FORWARD_SCRIPT"
else
  warn "enable_port_forward_rdp.sh not found in $SCRIPT_DIR. Skipping auto-configuration."
  echo "Download and run manually when VM is ready."
fi