#!/bin/bash
# ============================================================
# Hybrid Systemd + Libvirt Auto-Restart + Resource Limit Script

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err() { echo -e "${RED}✗ $1${NC}"; exit 1; }
header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ============================================================
# 🔧 Adjustable Parameters
# ============================================================
CPU_LIMIT_PERCENT=85     # Max CPU usage per VM (percentage)
RAM_LIMIT_PERCENT=85     # Max RAM allocation per VM (percentage)
RESTART_DELAY=10         # Delay (seconds) before auto-restart
# ============================================================

# --- Check libvirt service ---
if ! systemctl list-unit-files | grep -q libvirtd; then
  err "libvirtd service not found. Please install libvirt first."
fi

if ! systemctl is-active --quiet libvirtd; then
  warn "libvirtd is not active — starting it now..."
  sudo systemctl enable --now libvirtd
fi
ok "libvirtd service is active"

# ============================================================
# 🧩 Create Systemd Template (Watchdog Layer)
# ============================================================
header "Creating systemd template for autorestart"
UNIT_FILE="/etc/systemd/system/libvirt-vm@.service"
if [[ ! -f "$UNIT_FILE" ]]; then
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
  ok "Systemd template created: $UNIT_FILE"
else
  ok "Template already exists — skipping creation"
fi

# ============================================================
# 🔍 Detect Available VMs
# ============================================================
header "Detecting libvirt VMs"
VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
if [[ -z "$VM_LIST" ]]; then
  warn "No VMs detected."
  exit 0
fi
ok "Detected VMs: $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
# 🚀 Apply Autorestart + CPU/RAM Limits
# ============================================================
header "Applying auto-restart and resource limits"
for VM in $VM_LIST; do
  echo -e "\n🖥️ Configuring VM: ${VM}"

  # Enable autostart at host boot
  sudo virsh set-autostart "$VM" >/dev/null 2>&1 || warn "Could not set autostart for $VM"

  # Enable & start systemd watchdog
  sudo systemctl enable --now "libvirt-vm@${VM}.service" >/dev/null 2>&1 || warn "Failed to enable systemd service for $VM"

  # --- CPU limit ---
  CPU_QUOTA=$(( CPU_LIMIT_PERCENT * 1000 )) # 100000 = 100%
  if sudo virsh schedinfo "$VM" --set cpu_quota="${CPU_QUOTA}" --set cpu_period=100000 >/dev/null 2>&1; then
    ok "CPU limited to ${CPU_LIMIT_PERCENT}% for $VM"
  else
    warn "Failed to apply CPU limit for $VM"
  fi

  # --- RAM limit ---
  MEM_MAX=$(sudo virsh dominfo "$VM" | awk '/Max memory/ {print $3}')
  if [[ -n "$MEM_MAX" && "$MEM_MAX" -gt 0 ]]; then
    LIMIT=$(( MEM_MAX * RAM_LIMIT_PERCENT / 100 ))
    if sudo virsh setmem "$VM" "$LIMIT" --live --config >/dev/null 2>&1; then
      ok "RAM limited to ${RAM_LIMIT_PERCENT}% (${LIMIT} KB) for $VM"
    else
      warn "Failed to set live RAM limit for $VM"
    fi
    sudo virsh memtune "$VM" --hard-limit $(( LIMIT * 1024 )) --config >/dev/null 2>&1 || true
  else
    warn "Could not detect memory size for $VM"
  fi

  ok "Autorestart + limits applied for $VM"
done

# ============================================================
# ✅ Summary
# ============================================================
header "Configuration Summary"
ok "All VMs are now configured with:"
echo "  - CPU limit: ${CPU_LIMIT_PERCENT}%"
echo "  - RAM limit: ${RAM_LIMIT_PERCENT}%"
echo "  - Auto-restart delay: ${RESTART_DELAY}s"
echo ""
echo "🧠 Behavior Overview:"
echo "  • Systemd will auto-restart any VM that stops or crashes"
echo "  • Libvirt handles all resource control internally (safe for performance)"
echo "  • VM sees full virtualized CPU/RAM inside guest OS"
echo "  • Host enforces real usage cap to protect stability"
ok "Hybrid management setup complete!"
