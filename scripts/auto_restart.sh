#!/bin/bash
# ============================================================
# CPU usage limit by percentage (cgroup v2) + RAM limit + autostart
# For Debian 12 / Ubuntu 22+
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✗ $1${NC}"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}"; }

CPU_LIMIT_PERCENT=85      # target 85 % dari total host
RAM_LIMIT_PERCENT=85
RESTART_DELAY=10
QEMU_PATH="/var/lib/libvirt/qemu"

# ============================================================
header "Checking dependencies"
sudo apt-get update -y >/dev/null 2>&1
sudo apt-get install -y bc >/dev/null 2>&1
ok "All dependencies available"

# ============================================================
header "Applying host memory tuning"
sudo tee /etc/sysctl.d/99-memory-tuning.conf >/dev/null <<EOF
vm.swappiness=60
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF
sudo sysctl --system >/dev/null
ok "Memory tuning applied"

# ============================================================
header "Checking libvirt service"
systemctl is-active --quiet libvirtd || sudo systemctl enable --now libvirtd
ok "libvirtd is active"

# ============================================================
header "Detecting VMs"
VM_LIST=$(sudo virsh list --all --name | grep -v '^$' || true)
[[ -z "$VM_LIST" ]] && { warn "No VMs found."; exit 0; }
ok "Detected $(echo "$VM_LIST" | wc -l) VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
header "Host resources"
CPU_COUNT=$(nproc)
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB/1024))
RAM_LIMIT_MB=$((RAM_TOTAL_MB*RAM_LIMIT_PERCENT/100))
RAM_LIMIT_PER_VM_MB=$((RAM_LIMIT_MB/$(echo "$VM_LIST" | wc -l)))
RAM_LIMIT_PER_VM_GB=$((RAM_LIMIT_PER_VM_MB/1024))
ok "CPU: ${CPU_COUNT} cores | RAM: ${RAM_TOTAL_MB}MB (~${RAM_LIMIT_PER_VM_GB}GB per VM)"

# ============================================================
header "Configuring systemd template"
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
Restart=always
RestartSec=${RESTART_DELAY}

[Install]
WantedBy=multi-user.target
EOF
fi
sudo systemctl daemon-reload
ok "Template ready"

# ============================================================
header "Applying CPU(%), RAM limit & autostart"

for VM in $VM_LIST; do
  echo -e "\n🖥️  VM: $VM"

  # Persistent ensure
  if ! sudo virsh dominfo "$VM" | grep -q "Persistent:.*yes"; then
    sudo virsh dumpxml "$VM" | sudo tee "${QEMU_PATH}/${VM}.xml" >/dev/null
    sudo virsh define "${QEMU_PATH}/${VM}.xml" >/dev/null 2>&1 && ok "Persistent defined"
  fi

  # Autostart enable
  sudo virsh set-autostart "$VM" >/dev/null 2>&1 && ok "Autostart enabled" || warn "Autostart failed (ignore)"

  # rc.local fallback
  if [[ ! -f /etc/rc.local ]]; then
    sudo tee /etc/rc.local >/dev/null <<'EORC'
#!/bin/bash
for vm in $(virsh list --all --name | grep -v '^$'); do
  virsh start "$vm" >/dev/null 2>&1
done
exit 0
EORC
    sudo chmod +x /etc/rc.local
    sudo systemctl enable rc-local >/dev/null 2>&1 || true
    ok "rc.local autostart fallback created"
  fi

  # Start VM if off
  if ! sudo virsh domstate "$VM" | grep -q running; then
    sudo virsh start "$VM" >/dev/null 2>&1 && ok "VM started"
    sleep 5
  fi

  # ===== CPU LIMIT BY PERCENT (cputune XML) =====
  QUOTA=$((CPU_LIMIT_PERCENT * 1000))
  PERIOD=100000
  TMP_XML=$(mktemp)
  sudo virsh dumpxml "$VM" > "$TMP_XML"
  if ! grep -q "<cputune>" "$TMP_XML"; then
    sudo sed -i "/<cpu>/a\\
  <cputune>\\
    <quota>${QUOTA}</quota>\\
    <period>${PERIOD}</period>\\
  </cputune>" "$TMP_XML"
  else
    sudo sed -i "s|<quota>.*</quota>|<quota>${QUOTA}</quota>|" "$TMP_XML" || true
  fi
  sudo virsh define "$TMP_XML" >/dev/null 2>&1
  rm -f "$TMP_XML"
  ok "CPU limited to ${CPU_LIMIT_PERCENT}% of total host"

  # ===== RAM limit =====
  MEM_KB=$((RAM_LIMIT_PER_VM_MB*1024))
  sudo virsh setmem "$VM" "$MEM_KB" --config >/dev/null 2>&1 && ok "RAM limited to ~${RAM_LIMIT_PER_VM_GB}GB" || warn "RAM setmem failed"

  # systemd service
  sudo systemctl enable --now libvirt-vm@"$VM".service >/dev/null 2>&1 || true
done

# ============================================================
header "✅ Configuration complete"
echo "🔁 Autostart active via rc.local + systemd"
echo "⚙️  CPU usage capped globally to ${CPU_LIMIT_PERCENT}%"
echo "💾 RAM limited globally to ${RAM_LIMIT_PERCENT}%"
echo "📊 Effective per-VM:"
echo "   - CPU: ~${CPU_LIMIT_PERCENT}%"
echo "   - RAM: ~${RAM_LIMIT_PER_VM_GB}GB"
ok "All done! CPU limit now percentage-based."
