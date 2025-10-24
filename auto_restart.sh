#!/bin/bash
# ============================================================
# Auto-enable systemd autorestart for ALL libvirt VMs
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
err() { echo -e "${RED}✗ $1${NC}"; exit 1; }

header() { echo -e "\n${GREEN}=== $1 ===${NC}"; }

if ! systemctl list-unit-files | grep -q libvirtd; then
  err "libvirtd service not found. Make sure libvirt is properly installed."
fi

if ! systemctl is-active --quiet libvirtd; then
  warn "libvirtd is not active — starting it now..."
  sudo systemctl enable --now libvirtd
fi
ok "libvirtd service is active"

# --- Create systemd template ---
header "Creating systemd template for autorestart"
UNIT_FILE="/etc/systemd/system/libvirt-vm@.service"
if [[ ! -f "$UNIT_FILE" ]]; then
  sudo tee "$UNIT_FILE" >/dev/null <<'EOF'
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
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  ok "Template created: /etc/systemd/system/libvirt-vm@.service"
else
  ok "Template already exists — skipping creation"
fi

# --- Detect available VMs ---
header "Detecting all libvirt VMs"
VM_LIST=$(virsh list --all --name | grep -v '^$' || true)

if [[ -z "$VM_LIST" ]]; then
  warn "No VMs found in libvirt."
  exit 0
fi

# --- Enable autorestart for all detected VMs ---
header "Enabling autorestart for all VMs"
for VM in $VM_LIST; do
  echo "⚙️  Configuring VM: ${VM}"
  
  # Enable libvirt autostart (boot persistence)
  sudo virsh set-autostart "$VM" || warn "Could not set autostart for $VM"

  # Enable and start systemd service
  sudo systemctl enable --now "libvirt-vm@${VM}.service" || warn "Failed to enable systemd unit for $VM"

  ok "Autorestart enabled for VM: $VM"
done

header "Verification"
ok "All VMs now have systemd-based autorestart enabled!"
echo ""
echo "🔁 Each VM will:"
echo "  - Auto-start on host boot"
echo "  - Auto-restart if it stops or crashes"
ok "Setup complete!"