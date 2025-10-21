#!/bin/bash
# ============================================================
# Windows 10 LTSC UNATTENDED Installer for Debian 12+ / Ubuntu 22+
# Full automation with reboot handling (FIXED windowsPE parsing)
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
 libgnutls28-dev gnutls-bin libxml2-utils xorriso

# --- libvirt check ---
header "Checking libvirt/virsh"
SKIP_BUILD=false
if command -v virsh &>/dev/null; then
  VER=$(virsh --version 2>/dev/null || echo "unknown")
  if [[ "$VER" == "11.8.0" ]]; then ok "libvirt 11.8.0 detected — skipping build"; SKIP_BUILD=true
  else warn "Detected libvirt $VER → rebuilding to 11.8.0"; fi
else
  warn "libvirt not found, building 11.8.0"
fi

# --- Build libvirt 11.8.0 ---
if [[ "$SKIP_BUILD" == false ]]; then
  header "Building libvirt 11.8.0 from GitHub"
  sudo systemctl stop libvirtd 2>/dev/null || true
  sudo apt remove -y libvirt-daemon-system libvirt-clients libvirt-daemon || true
  cd /usr/src; sudo rm -rf libvirt
  step "Cloning libvirt v11.8.0..."
  if ! sudo git clone --branch v11.8.0 --depth 1 https://github.com/libvirt/libvirt.git; then
    warn "Tag v11.8.0 not found, trying v11.8.1..."
    sudo git clone --branch v11.8.1 --depth 1 https://github.com/libvirt/libvirt.git || {
      warn "Fallback to v11.7.0"; sudo git clone --branch v11.7.0 --depth 1 https://github.com/libvirt/libvirt.git; }
  fi
  cd libvirt
  step "Configuring Meson..."; sudo meson setup build --prefix=/usr -Ddriver_libvirtd=enabled -Ddriver_remote=enabled -Dsystem=true
  step "Building with Ninja..."; sudo ninja -C build
  step "Installing..."; sudo ninja -C build install
  sudo systemctl daemon-reexec; sudo systemctl daemon-reload
  sudo systemctl enable --now libvirtd
  systemctl is-active --quiet libvirtd && ok "libvirt built & running" || { err "Failed to start libvirtd"; cleanup_and_exit; }
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
else ok "Using cached virtio drivers: $VIRTIO_FILE"; fi
sudo ln -sf "$VIRTIO_FILE" "$VIRTIO_LINK"

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
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>E:\viostor\w10\amd64</Path></PathAndCredentials>
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
  xmllint --noout "$AUTOUNATTEND_DIR/autounattend.xml" || { err "Invalid XML syntax detected in autounattend.xml"; exit 1; }
  ok "Autounattend.xml validated successfully"
fi

ok "Autounattend.xml generated with username: ${WIN_USERNAME}"

# --- Create Floppy Image with autounattend.xml ---
FLOPPY_IMG="${ISO_CACHE}/autounattend-${VM_NAME}.img"
step "Creating floppy image with autounattend.xml..."
sudo dd if=/dev/zero of="$FLOPPY_IMG" bs=1024 count=1440 2>/dev/null
sudo mkfs.vfat "$FLOPPY_IMG" >/dev/null 2>&1
FLOPPY_MOUNT="/mnt/floppy-tmp-${VM_NAME}"
sudo mkdir -p "$FLOPPY_MOUNT"
sudo mount -o loop "$FLOPPY_IMG" "$FLOPPY_MOUNT"
sudo cp "$AUTOUNATTEND_DIR/autounattend.xml" "$FLOPPY_MOUNT/autounattend.xml"
sync
sudo umount "$FLOPPY_MOUNT"; sudo rmdir "$FLOPPY_MOUNT"
ok "Floppy image created: ${FLOPPY_IMG}"

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
ok "AppArmor disabled for libvirt"

sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default

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
  --boot hd,cdrom,menu=on \
  --disk "${VIRTIO_LINK}",device=cdrom \
  --disk "${FLOPPY_IMG}",device=floppy \
  --check path_in_use=off \
  --features hyperv_relaxed=on,hyperv_vapic=on,hyperv_spinlocks=on,hyperv_spinlocks_retries=8191 \
  --clock hypervclock_present=yes \
  --noautoconsole
ok "VM created: ${VM_NAME}"

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

# --- Add vhost driver and multiqueue ---
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

# --- Monitor installation and handle reboot ---
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
      echo ""; echo "🔄 Reboot detected! Changing boot order to HDD first..."
      REBOOT_DETECTED=true
      sudo virt-xml "${VM_NAME}" --edit --boot hd,cdrom 2>/dev/null || true
      sleep 5
      echo "🚀 Restarting VM..."
      sudo virsh start "${VM_NAME}" 2>/dev/null || true
      sleep 10
    else
      echo ""; warn "VM stopped unexpectedly, restarting..."
      sudo virsh start "${VM_NAME}" 2>/dev/null || true
      sleep 10
    fi
  fi

  if [[ "$REBOOT_DETECTED" == "true" ]] && (( CHECK_COUNT % 10 == 0 )); then
    VM_IP=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1 || echo "")
    if [[ -n "$VM_IP" ]]; then
      echo ""; echo "✅ Network detected! VM IP: ${VM_IP}"
      echo "🎉 Windows installation likely complete!"
      INSTALL_COMPLETE=true; break
    fi
  fi
  sleep 10
done

# --- Auto Port Forwarding for RDP ---
header "Auto Configuring RDP Port Forwarding"
echo "⏳ Waiting for VM IP to appear..."

VM_IP=""
for i in {1..60}; do
    VM_IP=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -n1 || true)
    if [[ -n "$VM_IP" ]]; then
        echo "✅ Detected VM IP: $VM_IP"
        break
    fi
    sleep 5
done

if [[ -z "$VM_IP" ]]; then
    warn "VM IP not detected after 5 minutes. Skipping port forwarding."
    exit 0
fi

echo ""
echo "=== [ Enable Port Forwarding for RDP - Debian ] ==="
PUB_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
if [ -z "$PUB_IF" ]; then
    err "Could not detect public network interface!"
    echo "Please check using: ip a"
    exit 1
fi

PUB_IP=$(ip -4 addr show dev "$PUB_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
echo "Detected public interface: $PUB_IF ($PUB_IP)"

RDP_PORT=3389
echo ""
echo "Forwarding RDP (TCP+UDP) from $PUB_IP:$RDP_PORT → $VM_NAME ($VM_IP:$RDP_PORT)"
echo ""

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Ensure nftables installed
if ! command -v nft >/dev/null 2>&1; then
    echo "Installing nftables..."
    apt-get update -qq && apt-get install -y nftables >/dev/null
fi

# Write nftables config
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;
        policy accept;
    }
    chain forward {
        type filter hook forward priority 0;
        policy accept;
    }
    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority 0;
        iif "$PUB_IF" tcp dport $RDP_PORT dnat to $VM_IP:$RDP_PORT
        iif "$PUB_IF" udp dport $RDP_PORT dnat to $VM_IP:$RDP_PORT
    }
    chain postrouting {
        type nat hook postrouting priority 100;
        oif "$PUB_IF" masquerade
    }
}
EOF

# Apply nftables
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

ok "RDP Port forwarding active!"
echo "🌐 Public RDP: ${PUB_IP}:${RDP_PORT} → VM: ${VM_IP}:${RDP_PORT}"
echo "⚠️ Ensure RDP service is running inside Windows and firewall is off."

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
  echo "  IP Address: ${VM_IP}"
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
  warn "Installation monitoring timed out after 30 minutes"
  echo ""
  echo "Please check VM status manually:"
  echo "  sudo virsh list --all"
  echo "  sudo virsh domifaddr ${VM_NAME}"
  echo ""
  echo "Connect via VNC to check progress:"
  echo "  ${YELLOW}$(hostname -I | awk '{print $1}'):${VNC_PORT}${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    VM MANAGEMENT COMMANDS                      ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  sudo virsh list --all                    # List all VMs"
echo "  sudo virsh start ${VM_NAME}              # Start VM"
echo "  sudo virsh shutdown ${VM_NAME}           # Graceful shutdown"
echo "  sudo virsh destroy ${VM_NAME}            # Force stop"
echo "  sudo virsh reboot ${VM_NAME}             # Reboot VM"
echo "  sudo virsh domifaddr ${VM_NAME}          # Check VM IP"
echo "  sudo virsh console ${VM_NAME}            # Serial console"
echo "  sudo virsh undefine ${VM_NAME} --remove-all-storage  # Delete VM"
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