#!/bin/bash
# ============================================================
# Windows 10 LTSC UNATTENDED Installer (Debian 12+ / Ubuntu 22+)
# Full GPU Passthrough (prompt-based PCI), No VNC, Nested KVM optimized
# Focus: Android Emulator / CI / Gaming / RDP performance
# ============================================================

VM_NAME=${1:-win10ltsc}
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
  if [[ "$ID" != "debian" && "$ID" != "ubuntu" ]]; then
    err "Only Debian and Ubuntu are supported"; cleanup_and_exit
  fi
  if [[ "$ID" == "debian" ]]; then
    (( ${VERSION_ID%%.*} < 12 )) && { err "Debian 12+ required"; cleanup_and_exit; }
    ok "Debian ${VERSION_ID} is supported"
  else
    [[ "${VERSION_ID%%.*}" -lt 22 ]] && { err "Ubuntu 22.04+ required"; cleanup_and_exit; }
    ok "Ubuntu ${VERSION_ID} is supported"
  fi
else
  err "Cannot detect OS - /etc/os-release not found"; cleanup_and_exit
fi

# --- KVM check ---
header "Checking KVM support"
if ! grep -E -q '(vmx|svm)' /proc/cpuinfo; then err "CPU virtualization not supported"; cleanup_and_exit; fi
[[ ! -e /dev/kvm ]] && { err "/dev/kvm missing"; cleanup_and_exit; }
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

# --- IOMMU sanity (for GPU passthrough) ---
header "Checking IOMMU (required for GPU passthrough)"
if ! dmesg | grep -qi -e 'IOMMU enabled' -e 'DMAR: IOMMU enabled' -e 'AMD-Vi: Enabling IOMMU' ; then
  warn "IOMMU may be disabled. If passthrough fails, enable kernel flags:"
  warn "  intel_iommu=on iommu=pt   (Intel)   |   amd_iommu=on iommu=pt   (AMD)"
fi

# --- Detect System Resources ---
header "Detecting System Resources"
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
echo "Total Physical RAM : ${TOTAL_RAM_MB} MB"
TOTAL_CPUS=$(nproc)
echo "Total CPU Cores    : ${TOTAL_CPUS}"
TOTAL_DISK_GB=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
FREE_DISK_GB=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
echo "Total Disk / Free  : ${TOTAL_DISK_GB} GB / ${FREE_DISK_GB} GB"

# --- Windows User Configuration ---
header "Windows User Configuration"
echo -e "${BLUE}Configure Windows administrator account:${NC}"
read -p "Username [Administrator]: " WIN_USERNAME
WIN_USERNAME=${WIN_USERNAME:-Administrator}
while true; do
  read -sp "Password (min 8 chars): " WIN_PASSWORD; echo ""
  [[ ${#WIN_PASSWORD} -lt 8 ]] && { warn "Password too short!"; continue; }
  read -sp "Confirm password: " WIN_PASSWORD_CONFIRM; echo ""
  [[ "$WIN_PASSWORD" == "$WIN_PASSWORD_CONFIRM" ]] && { ok "Password set for ${WIN_USERNAME}"; break; } || warn "Passwords don't match!"
done
read -p "Computer name [WIN10-LTSC]: " WIN_COMPUTERNAME
WIN_COMPUTERNAME=${WIN_COMPUTERNAME:-WIN10-VM}

# --- VM Config ---
header "VM Configuration"
read -p "RAM allocation (% of ${TOTAL_RAM_MB}MB) [50]: " RAM_PERCENT
RAM_PERCENT=${RAM_PERCENT:-50}
RAM_SIZE=$(( TOTAL_RAM_MB * RAM_PERCENT / 100 ))
(( RAM_SIZE < 4096 )) && { warn "Raising RAM to 4096MB minimum"; RAM_SIZE=4096; }
echo "Allocated RAM      : ${RAM_SIZE} MB"

MAX_VCPU=$TOTAL_CPUS
read -p "vCPU count (max: ${MAX_VCPU}) [4]: " VCPU_COUNT
VCPU_COUNT=${VCPU_COUNT:-4}
(( VCPU_COUNT > MAX_VCPU )) && { warn "Exceeds max; set to ${MAX_VCPU}"; VCPU_COUNT=$MAX_VCPU; }
(( VCPU_COUNT < 2 )) && { warn "Raising vCPU to 2 minimum"; VCPU_COUNT=2; }
echo "Allocated vCPUs    : ${VCPU_COUNT}"

read -p "Disk size in GB (max: ${FREE_DISK_GB}GB free) [60]: " DISK_SIZE
DISK_SIZE=${DISK_SIZE:-60}
(( DISK_SIZE > FREE_DISK_GB )) && { warn "Exceeds free; set to ${FREE_DISK_GB}GB"; DISK_SIZE=$FREE_DISK_GB; }
(( DISK_SIZE < 20 )) && { warn "Too small; set to 20GB"; DISK_SIZE=20; }
echo "Allocated Disk     : ${DISK_SIZE} GB"

# RDP/VNC
read -p "RDP port to expose (>=1024; default 3389): " RDP_PORT
RDP_PORT=${RDP_PORT:-3389}
[[ ! "$RDP_PORT" =~ ^[0-9]+$ || "$RDP_PORT" -lt 1024 ]] && { err "Invalid RDP port"; cleanup_and_exit; }

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
 pciutils

# --- libvirt check / install (lean) ---
header "Checking libvirt/virsh"
if ! command -v virsh &>/dev/null; then
  sudo apt install -y libvirt-daemon-system libvirt-clients
  sudo systemctl enable --now libvirtd virtqemud || true
fi
sudo systemctl is-active --quiet libvirtd || sudo systemctl restart libvirtd

# --- Swap setup ---
header "Configuring Swap"
read -p "Swap size in GB [4]: " SWAP_SIZE
SWAP_SIZE=${SWAP_SIZE:-4}
(( SWAP_SIZE < 1 )) && SWAP_SIZE=1
(( SWAP_SIZE > 16 )) && SWAP_SIZE=16
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

# Ensure libvirt users
if ! getent group libvirt-qemu >/dev/null; then sudo groupadd -r libvirt-qemu; fi
id libvirt-qemu &>/dev/null || sudo useradd -r -g libvirt-qemu -d /var/lib/libvirt -s /usr/sbin/nologin libvirt-qemu
if ! getent group libvirt-dnsmasq >/dev/null; then sudo groupadd -r libvirt-dnsmasq; fi
id libvirt-dnsmasq &>/dev/null || sudo useradd -r -g libvirt-dnsmasq -d /var/lib/libvirt/dnsmasq -s /usr/sbin/nologin libvirt-dnsmasq

# Windows ISO (same link as sebelumnya)
if [[ ! -f "$ISO_FILE" || $(stat -c%s "$ISO_FILE" 2>/dev/null || echo 0) -lt 1000000000 ]]; then
  step "Downloading Windows 10 LTSC ISO..."
  sudo wget -O "$ISO_FILE" "https://archive.org/download/windows10ltsc/windows_10_enterprise_ltsc_2019_x64_dvd_5795bb03.iso"
else ok "Using cached ISO: $ISO_FILE"; fi
[[ ! -f "$ISO_LINK" ]] && sudo cp -f "$ISO_FILE" "$ISO_LINK"
id libvirt-qemu &>/dev/null && sudo chown libvirt-qemu:libvirt-qemu "$ISO_LINK" || sudo chown root:root "$ISO_LINK"
sudo chmod 644 "$ISO_LINK"

# Virtio drivers
header "Preparing virtio Drivers"
VIRTIO_FILE="${ISO_CACHE}/virtio-win.iso"
VIRTIO_LINK="/var/lib/libvirt/boot/virtio-win.iso"
if [[ ! -f "$VIRTIO_FILE" || $(stat -c%s "$VIRTIO_FILE" 2>/dev/null || echo 0) -lt 50000000 ]]; then
  step "Downloading latest virtio-win drivers..."
  sudo wget -O "$VIRTIO_FILE" "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win.iso"
  ok "virtio drivers downloaded"
else ok "Using cached virtio drivers: $VIRTIO_FILE"; fi
[[ ! -f "$VIRTIO_LINK" ]] && sudo cp -f "$VIRTIO_FILE" "$VIRTIO_LINK"
id libvirt-qemu &>/dev/null && sudo chown libvirt-qemu:libvirt-qemu "$VIRTIO_LINK" || sudo chown root:root "$VIRTIO_LINK"
sudo chmod 644 "$VIRTIO_LINK"

# --- Unattended XML ---
header "Generating Unattended Installation File"
AUTOUNATTEND_DIR="/tmp/autounattend-${VM_NAME}"
rm -rf "$AUTOUNATTEND_DIR"; mkdir -p "$AUTOUNATTEND_DIR"
esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g; s/'"'"'/\&apos;/g'; }
WIN_USERNAME_ESC=$(echo "$WIN_USERNAME" | esc)
WIN_PASSWORD_ESC=$(echo "$WIN_PASSWORD" | esc)
WIN_COMPUTERNAME_ESC=$(echo "$WIN_COMPUTERNAME" | esc)

cat > "$AUTOUNATTEND_DIR/autounattend.xml" <<'XMLEOF'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>en-US</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DiskConfiguration>
        <Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
          <CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>
          <ModifyPartitions><ModifyPartition wcm:action="add"><Active>true</Active><Format>NTFS</Format><Label>System</Label><Order>1</Order><PartitionID>1</PartitionID></ModifyPartition></ModifyPartitions>
        </Disk>
      </DiskConfiguration>
      <ImageInstall>
        <OSImage>
          <InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom>
          <InstallTo><DiskID>0</DiskID><PartitionID>1</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI>
        </OSImage>
      </ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>VM User</FullName><Organization>VirtualMachine</Organization><ProductKey><WillShowUI>Never</WillShowUI></ProductKey></UserData>
      <DynamicUpdate><Enable>false</Enable></DynamicUpdate>
    </component>
    <component name="Microsoft-Windows-PnpCustomizationsWinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <DriverPaths>
        <PathAndCredentials wcm:action="add" wcm:keyValue="1"><Path>E:\vioscsi\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="2"><Path>E:\NetKVM\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="3"><Path>E:\vioserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="4"><Path>E:\Balloon\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="5"><Path>E:\qemupciserial\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="6"><Path>E:\qemufwcfg\w10\amd64</Path></PathCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="7"><Path>E:\pvpanic\w10\amd64</Path></PathAndCredentials>
        <PathAndCredentials wcm:action="add" wcm:keyValue="8"><Path>E:\vioinput\w10\amd64</Path></PathAndCredentials>
      </DriverPaths>
    </component>
  </settings>
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>COMPUTERNAME_PLACEHOLDER</ComputerName><TimeZone>UTC</TimeZone>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><fDenyTSConnections>false</fDenyTSConnections></component>
    <component name="Microsoft-Windows-TerminalServices-RDP-WinStationExtensions" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><UserAuthentication>1</UserAuthentication></component>
    <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <FirewallGroups><FirewallGroup wcm:action="add" wcm:keyValue="RemoteDesktop"><Active>true</Active><Group>Remote Desktop</Group><Profile>all</Profile></FirewallGroup></FirewallGroups>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <OOBE><HideEULAPage>true</HideEULAPage><HideLocalAccountScreen>true</HideLocalAccountScreen><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE><ProtectYourPC>3</ProtectYourPC><SkipUserOOBE>true</SkipUserOOBE><SkipMachineOOBE>true</SkipMachineOOBE></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Password><Value>PASSWORD_PLACEHOLDER</Value><PlainText>true</PlainText></Password><DisplayName>USERNAME_PLACEHOLDER</DisplayName><Group>Administrators</Group><Name>USERNAME_PLACEHOLDER</Name></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>USERNAME_PLACEHOLDER</Username><Password><Value>PASSWORD_PLACEHOLDER</Value><PlainText>true</PlainText></Password><LogonCount>1</LogonCount></AutoLogon>
      <FirstLogonCommands>
        <SynchronousCommand wcm:action="add"><Order>1</Order><CommandLine>cmd /c netsh advfirewall set allprofiles state off</CommandLine><Description>Disable Windows Firewall</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>2</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine><Description>Enable RDP</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>3</Order><CommandLine>cmd /c netsh advfirewall firewall add rule name="Remote Desktop" protocol=TCP dir=in localport=3389 action=allow</CommandLine><Description>Allow RDP Port</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>4</Order><CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v UserAuthentication /t REG_DWORD /d 1 /f &amp;&amp; reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" /v SecurityLayer /t REG_DWORD /d 1 /f</CommandLine><Description>Enable NLA (no TLS)</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>5</Order><CommandLine>cmd /c net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15</CommandLine><Description>Lockout policy</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>6</Order><CommandLine>cmd /c powercfg -change -monitor-timeout-ac 0</CommandLine><Description>Disable screen timeout</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>7</Order><CommandLine>cmd /c powercfg -change -standby-timeout-ac 0</CommandLine><Description>Disable sleep</Description></SynchronousCommand>
        <SynchronousCommand wcm:action="add"><Order>8</Order><CommandLine>cmd /c echo Installation Complete &gt; C:\install_complete.txt</CommandLine><Description>Mark complete</Description></SynchronousCommand>
      </FirstLogonCommands>
    </component>
  </settings>
</unattend>
XMLEOF

sed -i "s|USERNAME_PLACEHOLDER|${WIN_USERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|PASSWORD_PLACEHOLDER|${WIN_PASSWORD_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
sed -i "s|COMPUTERNAME_PLACEHOLDER|${WIN_COMPUTERNAME_ESC}|g" "$AUTOUNATTEND_DIR/autounattend.xml"
command -v xmllint &>/dev/null && xmllint --noout "$AUTOUNATTEND_DIR/autounattend.xml" 2>/dev/null || true
ok "Autounattend.xml generated"

# --- Floppy image (autounattend) ---
FLOPPY_IMG="${ISO_CACHE}/autounattend-${VM_NAME}.img"
step "Creating floppy image with autounattend.xml..."
sudo dd if=/dev/zero of="$FLOPPY_IMG" bs=1024 count=1440 status=none
sudo mkfs.vfat -F 12 "$FLOPPY_IMG" >/dev/null
FLOPPY_MOUNT="/mnt/floppy-tmp-${VM_NAME}"
sudo mkdir -p "$FLOPPY_MOUNT"
sudo mount -o loop "$FLOPPY_IMG" "$FLOPPY_MOUNT"
sudo cp "$AUTOUNATTEND_DIR/autounattend.xml" "$FLOPPY_MOUNT/autounattend.xml"
sync; sudo umount "$FLOPPY_MOUNT"; sudo rmdir "$FLOPPY_MOUNT" || true
ok "Floppy image created: ${FLOPPY_IMG}"

# --- Create Disk ---
header "Creating VM Disk"
sudo mkdir -p /var/lib/libvirt/images
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/${VM_NAME}.img ${DISK_SIZE}G
ok "Disk ${DISK_SIZE}G ready"

# --- Remove old VM ---
sudo virsh destroy ${VM_NAME} 2>/dev/null || true
sudo virsh undefine ${VM_NAME} --nvram --remove-all-storage 2>/dev/null || true

# --- AppArmor relax ---
header "Adjusting AppArmor for libvirt"
if grep -q '^security_driver' /etc/libvirt/qemu.conf 2>/dev/null; then
  sudo sed -i 's/^security_driver.*/security_driver = "none"/' /etc/libvirt/qemu.conf
else
  echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf
fi
sudo systemctl restart libvirtd
ok "AppArmor set to none for libvirt"

# --- libvirt default network (NAT + DHCP) ---
if sudo virsh net-info default &>/dev/null; then
  sudo virsh net-destroy default 2>/dev/null || true
  sudo virsh net-undefine default 2>/dev/null || true
fi
cat <<EOF | sudo virsh net-define /dev/stdin
<network>
  <name>default</name>
  <bridge name="virbr0" stp="on" delay="0"/>
  <forward mode="nat"/>
  <ip address="192.168.122.1" netmask="255.255.255.0">
    <dhcp><range start="192.168.122.2" end="192.168.122.254"/></dhcp>
  </ip>
</network>
EOF
sudo virsh net-start default
[[ -L /etc/libvirt/qemu/networks/autostart/default.xml ]] && sudo rm -f /etc/libvirt/qemu/networks/autostart/default.xml
sudo virsh net-autostart default || true
ok "Default network active"

# --- KVM permission for libvirt-qemu ---
header "Checking KVM access"
if [[ -e /dev/kvm ]]; then
  sudo chown root:kvm /dev/kvm
  sudo chmod 660 /dev/kvm
  id libvirt-qemu &>/dev/null && sudo usermod -aG kvm libvirt-qemu || true
  sudo systemctl restart libvirtd || true
  if sudo -u libvirt-qemu test -r /dev/kvm; then ok "libvirt-qemu can access /dev/kvm"; else warn "libvirt-qemu cannot access /dev/kvm — may fallback to TCG"; USE_TCG=true; fi
else
  warn "/dev/kvm not found — falling back to TCG"; USE_TCG=true
fi

# --- GPU Passthrough (manual prompt) ---
header "GPU Passthrough Configuration (No VNC)"
echo "List GPU/Display devices:"
lspci | grep -E "NVIDIA|VGA|3D" || true
read -p "Enter GPU PCI address (e.g., 0000:00:1e.0): " GPU_PCI
GPU_PCI=${GPU_PCI:-0000:00:1e.0}

if [[ -d "/sys/bus/pci/devices/${GPU_PCI}" ]]; then
  step "Binding GPU ${GPU_PCI} to vfio-pci..."
  sudo modprobe vfio-pci || true
  if [[ -L "/sys/bus/pci/devices/${GPU_PCI}/driver" ]]; then
    echo "➡️  Unbinding current driver"
    echo "${GPU_PCI}" | sudo tee "/sys/bus/pci/devices/${GPU_PCI}/driver/unbind" >/dev/null || true
  fi
  echo "${GPU_PCI}" | sudo tee /sys/bus/pci/drivers/vfio-pci/bind >/dev/null || true
  ok "GPU bound to vfio-pci: ${GPU_PCI}"
  GPU_FLAGS="--video none --graphics none --host-device ${GPU_PCI}"
else
  warn "Device ${GPU_PCI} not found; continuing without GPU passthrough"
  GPU_FLAGS="--video model=virtio"
fi

# --- CPU topology ---
CPU_CORES=$VCPU_COUNT; CPU_THREADS=1
if (( VCPU_COUNT >= 2 )); then
  if (( VCPU_COUNT % 2 == 0 )); then CPU_CORES=$((VCPU_COUNT/2)); CPU_THREADS=2; fi
fi

# --- Create VM (optimized IO, no Hyper-V flags) ---
header "Creating Virtual Machine"
sudo virt-install \
  --name "${VM_NAME}" \
  --ram "${RAM_SIZE}" \
  --vcpus "${VCPU_COUNT}",maxvcpus="${VCPU_COUNT}",sockets=1,cores="${CPU_CORES}",threads="${CPU_THREADS}" \
  --cpu host-passthrough,cache.mode=passthrough,check=none \
  --cdrom "${ISO_LINK}" \
  --disk path="/var/lib/libvirt/images/${VM_NAME}.img",size="${DISK_SIZE}",bus=scsi,discard=unmap,detect_zeroes=unmap,cache=writeback,aio=native,io=threads \
  --controller type=scsi,model=virtio-scsi \
  --controller type=virtio-serial \
  --os-variant win10 \
  --network network=default,model=virtio \
  --boot hd,cdrom,menu=on \
  --disk "${VIRTIO_LINK}",device=cdrom \
  --disk "${FLOPPY_IMG}",device=floppy \
  --check path_in_use=off \
  --rng device=/dev/urandom \
  --noautoconsole \
  ${GPU_FLAGS}
ok "VM created: ${VM_NAME}"

# --- Nested virt host modules ---
echo "🔧 Ensuring nested virtualization on host"
if grep -q vmx /proc/cpuinfo; then
  sudo modprobe -r kvm_intel 2>/dev/null || true
  sudo modprobe kvm_intel nested=1
  echo "options kvm_intel nested=1" | sudo tee /etc/modprobe.d/kvm_intel.conf >/dev/null
elif grep -q svm /proc/cpuinfo; then
  sudo modprobe -r kvm_amd 2>/dev/null || true
  sudo modprobe kvm_amd nested=1
  echo "options kvm_amd nested=1" | sudo tee /etc/modprobe.d/kvm_amd.conf >/dev/null
fi

# --- Remove Hyper-V flags; keep ACPI/APIC only (avoid WHPX path) ---
sudo virt-xml "${VM_NAME}" --edit --features acpi=on,apic=on 2>/dev/null || true
# virtio rng & balloon
sudo virt-xml "${VM_NAME}" --add-device --rng model=virtio 2>/dev/null || true
sudo virt-xml "${VM_NAME}" --add-device --memballoon model=virtio 2>/dev/null || true
# Force HDD first
sudo virt-xml "${VM_NAME}" --edit --boot hd,cdrom 2>/dev/null || true

# --- Hugepages (best-effort) ---
echo "⚡ Configuring huge pages (optional)"
HUGEPAGES_NEEDED=$(( (RAM_SIZE / 2) + 256 ))
AVAILABLE_MEM_MB=$(free -m | awk '/^Mem:/ {print $7}')
MAX_HUGEPAGES=$(( (AVAILABLE_MEM_MB - 512) / 2 ))
if (( HUGEPAGES_NEEDED <= MAX_HUGEPAGES )); then
  CUR=$(cat /proc/sys/vm/nr_hugepages || echo 0)
  if (( CUR < HUGEPAGES_NEEDED )); then
    echo ${HUGEPAGES_NEEDED} | sudo tee /proc/sys/vm/nr_hugepages >/dev/null
    ACT=$(cat /proc/sys/vm/nr_hugepages || echo 0)
    if (( ACT >= HUGEPAGES_NEEDED )); then
      grep -q "vm.nr_hugepages" /etc/sysctl.conf && sudo sed -i "s/^vm.nr_hugepages=.*/vm.nr_hugepages=${HUGEPAGES_NEEDED}/" /etc/sysctl.conf || echo "vm.nr_hugepages=${HUGEPAGES_NEEDED}" | sudo tee -a /etc/sysctl.conf >/dev/null
      ok "Huge pages configured: ${ACT}"; SKIP_HUGEPAGES=false
    else warn "Could allocate only ${ACT} huge pages"; SKIP_HUGEPAGES=true; fi
  else ok "Huge pages already configured: ${CUR}"; SKIP_HUGEPAGES=false; fi
else
  warn "Not enough free memory for hugepages"; SKIP_HUGEPAGES=true
fi

# --- vhost_net ---
if ! lsmod | grep -q vhost_net; then
  sudo modprobe vhost_net
  grep -q vhost_net /etc/modules 2>/dev/null || echo vhost_net | sudo tee -a /etc/modules >/dev/null
  ok "vhost_net loaded"
fi

# --- Stop VM to apply net queues & hugepages flags ---
echo "⏸️  Stopping VM for final configuration..."
sudo virsh shutdown "${VM_NAME}" 2>/dev/null || true
for i in {1..30}; do
  sudo virsh list --state-running | grep -q "${VM_NAME}" || break
  sleep 1
done
sudo virsh destroy "${VM_NAME}" 2>/dev/null || true

echo "⚙️  Enabling vhost multiqueue (${VCPU_COUNT} queues)"
sudo virt-xml "${VM_NAME}" --edit --network driver_name=vhost,driver_queues="${VCPU_COUNT}" 2>/dev/null || true
if [[ "${SKIP_HUGEPAGES:-true}" == "false" ]]; then
  sudo virt-xml "${VM_NAME}" --edit --memorybacking hugepages=on 2>/dev/null || true
fi

# --- CPU pinning (best-effort) ---
echo "🧠 Applying CPU pinning..."
HOST_CPUS=$(nproc)
for ((i=0; i< VCPU_COUNT; i++)); do
  PIN=$(( (i % HOST_CPUS) ))
  sudo virsh vcpupin "${VM_NAME}" "$i" "$PIN" >/dev/null 2>&1 || true
done
ok "CPU pinning applied"

# --- Start VM ---
header "Starting Windows Installation"
sudo virsh start "${VM_NAME}"
ok "VM started - Windows installation beginning..."
sleep 15

# --- Monitor installation ---
header "Monitoring Installation Progress"
echo -e "${BLUE}This may take 10-20 minutes depending on your system${NC}"
REBOOT_DETECTED=false
INSTALL_COMPLETE=false
CHECK_COUNT=0
MAX_CHECKS=180

while (( CHECK_COUNT < MAX_CHECKS )); do
  CHECK_COUNT=$((CHECK_COUNT+1))
  if sudo virsh list --state-running | grep -q "${VM_NAME}"; then echo -n "."; else
    if [[ "$REBOOT_DETECTED" == "false" ]]; then
      echo; echo "🔄 Reboot detected! Forcing HDD boot..."
      REBOOT_DETECTED=true; sudo virt-xml "${VM_NAME}" --edit --boot hd,cdrom 2>/dev/null || true
      sleep 5; echo "🚀 Restarting VM..."; sudo virsh start "${VM_NAME}" 2>/dev/null || true; sleep 10
    else
      echo; warn "VM stopped unexpectedly, restarting..."; sudo virsh start "${VM_NAME}" 2>/dev/null || true; sleep 10
    fi
  fi

  if (( CHECK_COUNT % 10 == 0 )); then
    VM_IP=$(sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -oP '(\d{1,3}\.){3}\d{1,3}' | head -1 || echo "")
    if [[ -n "$VM_IP" ]]; then echo; echo "✅ Network detected! VM IP: ${VM_IP}"; echo "🎉 Windows installation likely complete!"; INSTALL_COMPLETE=true; break; fi
  fi

  if (( CHECK_COUNT % 20 == 0 )) && command -v guestfish >/dev/null 2>&1; then
    IMG="/var/lib/libvirt/images/${VM_NAME}.img"
    if sudo guestfish --ro -a "$IMG" -i sh "test -f /install_complete.txt || test -f /Windows/System32/winload.exe" >/dev/null 2>&1; then
      echo; echo "✅ Installation artifacts found on disk."; INSTALL_COMPLETE=true; break
    fi
  fi
  sleep 10
done

sleep 10
set +e
echo "⏳ Waiting for VM network initialization..."
MAX_WAIT=60; IP_DETECTED=false
for i in $(seq 1 $MAX_WAIT); do
  sudo virsh dominfo "${VM_NAME}" &>/dev/null || { echo ""; echo "⚠️ VM not defined"; break; }
  VM_COUNT=$(sudo virsh list --name 2>/dev/null | grep -c -v '^$' || echo "0")
  if [[ "$VM_COUNT" == "0" ]]; then echo ""; echo "⚠️ No running VMs; starting ${VM_NAME}..."; sudo virsh start "${VM_NAME}" >/dev/null 2>&1; sleep 5; continue; fi
  if sudo virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -q 'ipv4'; then echo ""; echo "✓ VM IP detected after ${i}s"; IP_DETECTED=true; sleep 5; break; fi
  (( i % 10 == 0 )) && { echo ""; echo "   ... still waiting (${i}s / ${MAX_WAIT}s)"; } || echo -n "."
  sleep 1
done
set -e

echo ""
if [[ "$INSTALL_COMPLETE" == "true" ]]; then
  header "Installation Complete!"
  ok "Windows 10 LTSC installed successfully!"
  echo -e "${BLUE}Next steps:${NC}"
  echo "1) RDP to the VM (map RDP port below)."
  echo "2) Install NVIDIA L4 / Data Center driver in Windows."
  echo "3) Android Emulator: use '-gpu host -accel on'."
else
  warn "Installation monitoring timed out"
fi

echo -e "\n${BLUE}Resource Allocation:${NC}"
echo "  RAM: ${RAM_SIZE} MB (${RAM_PERCENT}% of ${TOTAL_RAM_MB} MB)"
echo "  vCPUs: ${VCPU_COUNT} of ${TOTAL_CPUS} (topology: cores=${CPU_CORES}, threads=${CPU_THREADS})"
echo "  Disk: ${DISK_SIZE} GB"
echo -e "\n${BLUE}Performance Features:${NC}"
echo "  ✓ KVM accel (nested)   ✓ Host CPU passthrough"
echo "  ✓ VirtIO storage/net   ✓ cache=writeback + aio=native + io=threads"
echo "  ✓ RNG + Balloon        ✓ vhost multiqueue=${VCPU_COUNT}"
[[ "${SKIP_HUGEPAGES:-true}" == "false" ]] && echo "  ✓ Hugepages enabled" || echo "  ○ Hugepages skipped"
[[ -n "${GPU_PCI:-}" ]] && echo "  ✓ GPU passthrough: ${GPU_PCI} (no VNC)" || echo "  ○ No GPU passthrough"

# --- Auto restart hook ---
if [[ -f "$AUTO_RESTART_SCRIPT" ]]; then
  echo -e "\n🚀 Configuring VM auto-restart..."
  sudo bash "$AUTO_RESTART_SCRIPT"
else
  echo "No auto restart when vm stopped"
fi

# --- Port forward hook ---
if [[ -f "$PORT_FORWARD_SCRIPT" ]]; then
  echo -e "\n🚀 Configuring RDP port forwarding..."
  sudo bash "$PORT_FORWARD_SCRIPT" "$RDP_PORT"
else
  warn "enable_port_forward_rdp.sh not found in $SCRIPT_DIR. Skipping auto-configuration."
fi
