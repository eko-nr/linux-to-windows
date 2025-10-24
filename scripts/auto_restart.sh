#!/bin/bash
# ============================================================
# 🧩 Hybrid Libvirt Manager + Auto-Restart + CPU/RAM Limit 85%
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err() { echo -e "${RED}✗ $1${NC}"; exit 1; }
header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ============================================================
# ⚙️ Global Configuration
# ============================================================
GLOBAL_LIMIT_CPU_PERCENT=85
GLOBAL_LIMIT_RAM_PERCENT=85
RESTART_DELAY=10

# ============================================================
# 🧰 Section 1: Dependencies
# ============================================================
header "Checking dependencies"
if ! command -v bc >/dev/null 2>&1; then
  ok "Installing missing dependency: bc"
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y bc >/dev/null 2>&1
fi
ok "All dependencies available"

# ============================================================
# 🧠 Section 2: Host Memory Optimization
# ============================================================
header "Applying host memory tuning"
SYSCTL_FILE="/etc/sysctl.d/99-memory-tuning.conf"

sudo tee "$SYSCTL_FILE" >/dev/null <<'EOF'
vm.swappiness=60
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF

sudo sysctl --system >/dev/null
ok "Memory tuning applied (swappiness=60, cache_pressure=50, dirty_ratio=15/5)"

# ============================================================
# 🧩 Section 3: Ensure libvirt is active
# ============================================================
header "Checking libvirt service"
if ! systemctl list-unit-files | grep -q libvirtd; then
  err "libvirtd service not found. Please install libvirt first."
fi

if ! systemctl is-active --quiet libvirtd; then
  warn "libvirtd inactive — starting now..."
  sudo systemctl enable --now libvirtd
fi
ok "libvirtd is active"

# ============================================================
# ⚙️ Section 4: Create systemd autorestart unit
# ============================================================
UNIT_FILE="/etc/systemd/system/libvirt-vm@.service"
if [[ ! -f "$UNIT_FILE" ]]; then
  header "Creating systemd template"
  sudo tee "$UNIT_FILE" >/dev/null <<EOF
[Unit]
Description=Auto-start libvirt VM %i
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/virsh start %i
ExecStop=/usr/bin/virsh shutdown %i
RemainAfterExit=yes
Restart=on-failure
RestartSec=${RESTART_DELAY}

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  ok "Template created: $UNIT_FILE"
else
  ok "Template already exists"
fi

# ============================================================
# 🔍 Section 5: Detect VMs
# ============================================================
header "Detecting libvirt VMs"
VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
if [[ -z "$VM_LIST" ]]; then
  warn "No VMs found. Nothing to configure."
  exit 0
fi
VM_COUNT=$(echo "$VM_LIST" | wc -l)
ok "Detected $VM_COUNT VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
# ⚙️ Section 6: Calculate Limits
# ============================================================
TOTAL_CPUS=$(nproc)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_CPU_QUOTA=$(( TOTAL_CPUS * GLOBAL_LIMIT_CPU_PERCENT * 1000 ))
CPU_LIMIT_PER_VM=$(( TOTAL_CPU_QUOTA / VM_COUNT / 1000 ))
TOTAL_RAM_LIMIT_KB=$(( TOTAL_RAM_KB * GLOBAL_LIMIT_RAM_PERCENT / 100 ))
RAM_LIMIT_PER_VM_KB=$(( TOTAL_RAM_LIMIT_KB / VM_COUNT ))
RAM_LIMIT_PER_VM_MB=$(( RAM_LIMIT_PER_VM_KB / 1024 ))
RAM_LIMIT_PER_VM_GB=$(( RAM_LIMIT_PER_VM_MB / 1024 ))

header "Host Resource Summary"
echo "🧠 Total CPU cores : ${TOTAL_CPUS}"
echo "💾 Total RAM (KB)  : ${TOTAL_RAM_KB}"
echo "⚙️ Global CPU cap   : ${GLOBAL_LIMIT_CPU_PERCENT}%"
echo "💽 Global RAM cap   : ${GLOBAL_LIMIT_RAM_PERCENT}%"
echo "🔢 VM count         : ${VM_COUNT}"
echo "🚀 CPU per VM limit : ~${CPU_LIMIT_PER_VM}% effective"
echo "💡 RAM per VM limit : ~${RAM_LIMIT_PER_VM_GB} GB"

# ============================================================
# 🚀 Section 7: Apply per-VM limits
# ============================================================
header "Applying limits + autorestart"

for VM in $VM_LIST; do
  echo -e "\n🖥️ Configuring VM: ${VM}"

  sudo virsh set-autostart "$VM" >/dev/null 2>&1 || warn "Failed to set autostart for $VM"
  sudo systemctl enable --now "libvirt-vm@${VM}.service" >/dev/null 2>&1 || warn "Failed to enable systemd unit for $VM"

  # Apply CPU limit
  if sudo virsh schedinfo "$VM" \
    --set cpu_period=100000 \
    --set cpu_quota=$(( CPU_LIMIT_PER_VM * 1000 )) >/dev/null 2>&1; then
    ok "CPU limited to ${CPU_LIMIT_PER_VM}% for ${VM}"
  else
    warn "Failed to set CPU limit for ${VM}"
  fi

  # Apply RAM limit
  MEM_MAX=$(sudo virsh dominfo "$VM" | awk '/Max memory/ {print $3}')
  if [[ -n "$MEM_MAX" && "$MEM_MAX" -gt 0 ]]; then
    MEM_LIMIT=$(( RAM_LIMIT_PER_VM_KB < MEM_MAX ? RAM_LIMIT_PER_VM_KB : MEM_MAX ))
    sudo virsh setmem "$VM" "$MEM_LIMIT" --live --config >/dev/null 2>&1 || warn "setmem failed for $VM"
    sudo virsh memtune "$VM" --hard-limit $(( MEM_LIMIT * 1024 )) --config >/dev/null 2>&1 || true
    ok "RAM limited to ~${RAM_LIMIT_PER_VM_GB} GB for ${VM}"
  else
    warn "Could not detect memory size for ${VM}"
  fi

  ok "Limit + restart applied for ${VM}"
done

# ============================================================
# ✅ Section 8: Summary
# ============================================================
header "✅ Configuration Complete"
echo "🔁 All VMs auto-start on host boot"
echo "🧩 Auto-restart enabled (systemd watchdog)"
echo "⚙️ CPU limited globally to ${GLOBAL_LIMIT_CPU_PERCENT}% of host"
echo "💾 RAM limited globally to ${GLOBAL_LIMIT_RAM_PERCENT}% of host"
echo "📊 Current per-VM limit:"
echo "   - CPU: ~${CPU_LIMIT_PER_VM}%"
echo "   - RAM: ~${RAM_LIMIT_PER_VM_GB} GB"
echo ""
ok "All done! Host tuning and VM limits active successfully!"
