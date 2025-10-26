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

### 2. Run Installer
```bash
bash install.sh
```

## 📦 Available Scripts

### Main Installer
| Script | Function |
|--------|----------|
| `install.sh` | Main script for Windows 10 LTSC VM installation |

### VM Management Scripts (Root Directory)
| Script | Function |
|--------|----------|
| `start_all_vm.sh` | Start all VMs at once |
| `stop_all_vm.sh` | Stop all VMs at once |
| `uninstall.sh` | Uninstall/remove VM and its data |

### Scripts Directory (`scripts/`)
| Script | Function |
|--------|----------|
| `auto_restart.sh` | Auto-restart VM utility |
| `create_swap.sh` | Create swap file utility |
| `enable_port_forward_rdp.sh` | Enable port forwarding for RDP connections |
| `install_win10atlas.sh` | Windows 10 Atlas installation script |
| `install_win10ltsc.sh` | Windows 10 LTSC installation script |
| `install_win10tiny.sh` | Windows 10 Tiny installation script |
| `limit.sh` | Resource limiting utility |
| `partition.sh` | Disk partitioning utility |
| `uninstall_win10atlas.sh` | Uninstall Windows 10 Atlas VM |
| `uninstall_win10ltsc.sh` | Uninstall Windows 10 LTSC VM |
| `uninstall_win10tiny.sh` | Uninstall Windows 10 Tiny VM |

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
   bash scripts/enable_port_forward_rdp.sh
   ```
4. **Connect via RDP:**
   ```
   RDP Address: <server-ip>:3389
   ```

## 🔧 VM Management

### Start Single VM
```bash
sudo virsh start win10ltsc
```

### Stop Single VM
```bash
sudo virsh shutdown win10ltsc
```

### Force Stop VM
```bash
sudo virsh destroy win10ltsc
```

### Start All VMs
```bash
bash start_all_vm.sh
```

### Stop All VMs
```bash
bash stop_all_vm.sh
```

### Check VM Status
```bash
sudo virsh list --all
```

### Uninstall VM
```bash
# Using uninstall script
bash uninstall.sh

# Or using specific uninstall scripts
bash scripts/uninstall_win10ltsc.sh
bash scripts/uninstall_win10atlas.sh
bash scripts/uninstall_win10tiny.sh

# Or using virsh directly
sudo virsh undefine win10ltsc --remove-all-storage
```

### Auto-Restart VM
```bash
bash scripts/auto_restart.sh
```

## 📁 Directory Structure

```
linux-to-windows/
├── FRP/                              # FRP configuration files
├── rathole/                          # Rathole configuration files
├── scripts/                          # Utility scripts directory
│   ├── auto_restart.sh              # Auto-restart VM utility
│   ├── create_swap.sh               # Create swap file utility
│   ├── enable_port_forward_rdp.sh   # Enable RDP port forwarding
│   ├── install_win10atlas.sh        # Windows 10 Atlas installer
│   ├── install_win10ltsc.sh         # Windows 10 LTSC installer
│   ├── install_win10tiny.sh         # Windows 10 Tiny installer
│   ├── limit.sh                     # Resource limiting utility
│   ├── partition.sh                 # Disk partitioning utility
│   ├── uninstall_win10atlas.sh      # Uninstall Atlas VM
│   ├── uninstall_win10ltsc.sh       # Uninstall LTSC VM
│   └── uninstall_win10tiny.sh       # Uninstall Tiny VM
├── windows/                          # Windows-specific files
├── install.sh                        # Main installer script
├── start_all_vm.sh                   # Start all VMs
├── stop_all_vm.sh                    # Stop all VMs
├── uninstall.sh                      # Main uninstall script
└── README.md                         # This file
```

## 📂 Important System Directories

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
- Run `bash scripts/enable_port_forward_rdp.sh`
- Check if port 3389 is allowed in host firewall

## 📝 Notes

- The script supports multiple Windows 10 variants:
  - **LTSC** (Long-Term Servicing Channel) - Stable enterprise version
  - **Atlas** - Optimized lightweight version
  - **Tiny** - Minimal lightweight version
- ISO files are cached in `/opt/vm-isos/` for future use
- The installer builds libvirt 11.8.0 from source if not already installed
- Default network is NAT (requires port forwarding for external access)
- Management scripts are available both in root directory and `scripts/` directory

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