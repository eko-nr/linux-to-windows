# Windows 10 LTSC VM Installer

Automated installer for creating Windows 10 LTSC Virtual Machine on Debian 12+ or Ubuntu 22+ using QEMU/KVM.

## 📋 System Requirements

### Operating System
- **Debian 12 (Bookworm)** or higher
- **Ubuntu 22.04 LTS** or higher

### Hardware
- CPU with virtualization support (Intel VT-x or AMD-V)
- Minimum 4GB RAM (8GB+ recommended)
- Minimum 30GB free disk space
- Root/sudo access

### Software
- KVM support (`/dev/kvm` must be available)
- Internet connection for downloading dependencies and ISO

## 🚀 Installation

### 1. Clone or Download Repository
```bash
git clone https://github.com/eko-nr/linux-to-windows
cd linux-to-windows
```

### 2. Grant Execute Permissions
```bash
chmod +x install.sh
chmod +x enable_port_forward_rdp.sh
chmod +x start_vm.sh
chmod +x stop_vm.sh
chmod +x uninstall_vm.sh
chmod +x partition.sh
chmod +x limits.sh
```

### 3. Run Installer
```bash
bash install.sh
```

## 📦 Script List

| Script | Function |
|--------|----------|
| `install.sh` | Main script for Windows 10 LTSC VM installation |
| `enable_port_forward_rdp.sh` | Enable port forwarding for RDP connections |
| `start_vm.sh` | Start/run the VM |
| `stop_vm.sh` | Stop/shutdown the VM |
| `uninstall_vm.sh` | Uninstall/remove VM and its data |
| `partition.sh` | Disk partitioning utility |
| `limits.sh` | Resource limiting utility |

## ⚙️ VM Configuration

When running `install.sh`, you will be prompted to enter:

1. **VM Name** (default: win10ltsc)
2. **RAM Allocation** - Percentage of total RAM (default: 50%)
3. **vCPU Count** - Number of CPU cores (default: 2)
4. **Disk Size** - Disk size in GB (default: 50GB, min: 20GB)
5. **VNC Port** - Port for VNC connection (default: 5901)
6. **Swap Size** - Swap size in GB (default: 4GB, min: 1GB, max: 16GB)

## 🖥️ Accessing the VM

### Via VNC
After installation completes, the VM can be accessed via VNC:

```
VNC Address: <server-ip>:5901
```

Use a VNC client such as:
- TigerVNC Viewer
- RealVNC
- TightVNC
- Remmina (Linux)

### Via RDP (Remote Desktop Protocol)

To enable RDP access:

1. **Connect to VM via VNC first**
2. **Inside Windows:**
   - Enable Remote Desktop in Windows Settings
   - **Disable Windows Firewall** (required to accept RDP connections)
3. **On the host machine, run:**
   ```bash
   bash enable_port_forward_rdp.sh
   ```
4. **Connect via RDP:**
   ```
   RDP Address: <server-ip>:3389
   ```

## 🔧 VM Management

### Start VM
```bash
bash start_vm.sh
# or
sudo virsh start win10ltsc
```

### Stop VM
```bash
bash stop_vm.sh
# or
sudo virsh shutdown win10ltsc
```

### Force Stop VM
```bash
sudo virsh destroy win10ltsc
```

### Check VM Status
```bash
sudo virsh list --all
```

### Uninstall VM
```bash
bash uninstall_vm.sh
# or
sudo virsh undefine win10ltsc --remove-all-storage
```

## 📁 Important Directories

| Path | Description |
|------|-------------|
| `/opt/vm-isos/` | ISO file cache directory |
| `/var/lib/libvirt/images/` | VM disk images storage |
| `/var/lib/libvirt/boot/` | Boot ISO symlinks |

## 🛠️ Troubleshooting

### KVM not available
```bash
# Check if virtualization is enabled in BIOS
grep -E '(vmx|svm)' /proc/cpuinfo

# Check if KVM modules are loaded
lsmod | grep kvm

# Load KVM modules manually
sudo modprobe kvm_intel  # for Intel
sudo modprobe kvm_amd    # for AMD
```

### libvirtd not running
```bash
# Check libvirtd status
sudo systemctl status libvirtd

# Start libvirtd
sudo systemctl start libvirtd

# Enable libvirtd on boot
sudo systemctl enable libvirtd
```

### VNC connection refused
```bash
# Check if VM is running
sudo virsh list

# Check VNC port
sudo virsh vncdisplay win10ltsc

# Check firewall (if enabled)
sudo ufw allow 5901/tcp
```

### RDP not working
- Ensure Remote Desktop is enabled in Windows
- Ensure Windows Firewall is disabled
- Run `bash enable_port_forward_rdp.sh`
- Check if port 3389 is allowed in host firewall

## 📝 Notes

- The script automatically downloads Windows 10 LTSC ISO from archive.org
- ISO file is cached in `/opt/vm-isos/` for future use
- The installer builds libvirt 11.8.0 from source if not already installed
- Default network is NAT (requires port forwarding for external access)

## ⚠️ Security Warnings

- VNC listens on `0.0.0.0` (all interfaces) - use firewall to restrict access
- Consider using SSH tunneling for VNC connections over internet
- Disabling Windows Firewall reduces security - only do this on trusted networks
- Change default Windows password after first login

## 📄 License

This project is provided as-is without warranty.

## 🤝 Contributing

Feel free to submit issues or pull requests for improvements.

## 📧 Support

For issues and questions, please open an issue in the repository.