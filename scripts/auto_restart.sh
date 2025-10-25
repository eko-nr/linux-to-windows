#!/bin/bash
# ============================================================
# CPU/RAM Limiter + Autorestart
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✗ $1${NC}"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}"; }

CPU_LIMIT_PERCENT=85
RAM_LIMIT_PERCENT=85
MONITOR_INTERVAL=30

# ============================================================
header "0. Checking cgroup v2"

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo "unknown")

if [[ "$CGROUP_TYPE" != "cgroup2fs" ]]; then
  warn "Cgroup v2 not detected! Enabling now..."
  
  # Backup grub
  cp /etc/default/grub /etc/default/grub.backup
  
  # Check if already has the parameter
  if grep -q "systemd.unified_cgroup_hierarchy=1" /etc/default/grub; then
    ok "Cgroup v2 parameter already in grub"
  else
    # Add cgroup v2 parameter
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
    ok "Added cgroup v2 to grub config"
  fi
  
  # Update grub
  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  else
    err "Cannot find grub update command"
  fi
  
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  REBOOT REQUIRED to enable cgroup v2"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Run this script again after reboot:"
  echo "  bash $0"
  echo ""
  read -p "Reboot now? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
  else
    exit 0
  fi
else
  ok "Cgroup v2 is active (cgroup2fs)"
fi

# ============================================================
header "1. Checking prerequisites"
[[ $(id -u) -ne 0 ]] && err "Must run as root"
command -v bc >/dev/null || apt-get update && apt-get install -y bc
systemctl is-active --quiet libvirtd || systemctl enable --now libvirtd
ok "System ready"

# ============================================================
header "2. Detecting VMs"
VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
[[ -z "$VM_LIST" ]] && err "No VMs found"
VM_COUNT=$(echo "$VM_LIST" | wc -l)
ok "Found ${VM_COUNT} VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
header "3. Calculating resources"
CPU_COUNT=$(nproc)
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB/1024))
RAM_LIMIT_MB=$((RAM_TOTAL_MB*RAM_LIMIT_PERCENT/100))
RAM_LIMIT_PER_VM_MB=$((RAM_LIMIT_MB/VM_COUNT))
RAM_LIMIT_PER_VM_BYTES=$((RAM_LIMIT_PER_VM_MB * 1024 * 1024))

ok "CPU: ${CPU_COUNT} cores @ ${CPU_LIMIT_PERCENT}% each VM"
ok "RAM: ${RAM_TOTAL_MB}MB total → ~$((RAM_LIMIT_PER_VM_MB/1024))GB per VM"

# ============================================================
header "4. Creating systemd services for each VM"

for VM in $VM_LIST; do
  echo -e "\n🖥️  Configuring: $VM"
  
  # 4a. Make VM persistent
  if ! virsh dominfo "$VM" 2>/dev/null | grep -q "Persistent:.*yes"; then
    virsh dumpxml "$VM" > "/tmp/${VM}.xml"
    virsh define "/tmp/${VM}.xml" && rm "/tmp/${VM}.xml"
    ok "Made persistent"
  fi

  # 4b. Enable libvirt autostart
  virsh autostart "$VM" 2>/dev/null || warn "Autostart command failed (may already be set)"
  
  # 4c. Create systemd service for this VM
  SERVICE_FILE="/etc/systemd/system/libvirt-vm-${VM}.service"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Libvirt VM: ${VM}
After=libvirtd.service network.target
Requires=libvirtd.service
PartOf=libvirtd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/virsh start ${VM}
ExecStop=/usr/bin/virsh shutdown ${VM}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  
  systemctl daemon-reload
  systemctl enable "libvirt-vm-${VM}.service"
  ok "Systemd service created & enabled"
  
  # 4d. Update VM XML with CPU limit (persistent)
  TMP_XML=$(mktemp)
  virsh dumpxml "$VM" > "$TMP_XML"
  
  CPU_QUOTA=$((CPU_LIMIT_PERCENT * 1000 * CPU_COUNT))
  
  if grep -q "<cputune>" "$TMP_XML"; then
    sed -i "s|<quota>.*</quota>|<quota>${CPU_QUOTA}</quota>|" "$TMP_XML"
    sed -i "s|<period>.*</period>|<period>100000</period>|" "$TMP_XML"
  else
    sed -i "/<domain/a\\  <cputune>\\n    <quota>${CPU_QUOTA}</quota>\\n    <period>100000</period>\\n  </cputune>" "$TMP_XML"
  fi
  
  virsh define "$TMP_XML"
  rm -f "$TMP_XML"
  ok "CPU limit configured in XML"
  
  # 4e. Set RAM limit (persistent)
  RAM_LIMIT_KB=$((RAM_LIMIT_PER_VM_MB * 1024))
  virsh setmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null || warn "RAM setmem failed (may need VM restart)"
  ok "RAM limit set to ~$((RAM_LIMIT_PER_VM_MB/1024))GB"
  
  # 4f. Start VM if not running
  if ! virsh domstate "$VM" 2>/dev/null | grep -q running; then
    virsh start "$VM" && ok "VM started" || warn "Could not start VM"
    sleep 3
  fi
  
  # 4g. Apply live cgroup limits (OPTIONAL - can cause temporary freeze)
  # Uncomment below if you need INSTANT limits without VM restart
  # WARNING: May cause 2-10 sec UI freeze if VM is under heavy load
  
  : <<'COMMENTED_CGROUP_DIRECT'
  VM_ID=$(virsh domid "$VM" 2>/dev/null || echo "")
  if [[ -n "$VM_ID" ]]; then
    # Find cgroup path (handle escaped characters)
    CGROUP_BASE="/sys/fs/cgroup/machine.slice"
    CGROUP_PATTERN="machine-qemu*${VM_ID}*${VM}*.scope"
    CGROUP_PATH=$(find "$CGROUP_BASE" -maxdepth 1 -type d -name "$CGROUP_PATTERN" 2>/dev/null | head -n1)
    
    if [[ -n "$CGROUP_PATH" && -d "$CGROUP_PATH" ]]; then
      # CPU limit (live)
      echo "${CPU_QUOTA} 100000" > "${CGROUP_PATH}/cpu.max" 2>/dev/null && ok "Live CPU limit applied" || warn "Could not apply live CPU limit"
      
      # RAM limit (live)
      echo "$RAM_LIMIT_PER_VM_BYTES" > "${CGROUP_PATH}/memory.max" 2>/dev/null && ok "Live RAM limit applied" || warn "Could not apply live RAM limit"
    else
      warn "Cgroup path not found (VM may need restart for live limits)"
    fi
  fi
COMMENTED_CGROUP_DIRECT
  
  warn "Direct cgroup limits disabled (prevents freeze). Restart VM to apply limits."
done

# ============================================================
header "5. Creating VM monitor script"

MONITOR_SCRIPT="/usr/local/bin/vm-monitor.sh"
cat > "$MONITOR_SCRIPT" <<'EOMONITOR'
#!/bin/bash
# VM crash monitor - auto restart VMs

while true; do
  for VM in $(virsh list --all --name | grep -v '^$'); do
    # Check if VM should be running (autostart enabled)
    if virsh dominfo "$VM" 2>/dev/null | grep -q "Autostart:.*enable"; then
      # Check if VM is actually running
      if ! virsh domstate "$VM" 2>/dev/null | grep -q running; then
        echo "[$(date)] VM $VM is down, restarting..." | systemd-cat -t vm-monitor
        virsh start "$VM" 2>/dev/null
        sleep 5
      fi
    fi
  done
  sleep 30
done
EOMONITOR

chmod +x "$MONITOR_SCRIPT"
ok "Monitor script created"

# ============================================================
header "6. Creating monitor systemd service"

cat > /etc/systemd/system/vm-monitor.service <<EOF
[Unit]
Description=VM Crash Monitor & Auto-restart
After=libvirtd.service
Requires=libvirtd.service

[Service]
Type=simple
ExecStart=${MONITOR_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable vm-monitor.service
systemctl restart vm-monitor.service
ok "Monitor service started"

# ============================================================
header "7. Creating rc.local fallback (for host reboot)"

cat > /etc/rc.local <<'EORCLOCAL'
#!/bin/bash
# Fallback autostart for VMs on host boot
sleep 10
for vm in $(virsh list --all --name | grep -v '^$'); do
  if virsh dominfo "$vm" 2>/dev/null | grep -q "Autostart:.*enable"; then
    virsh start "$vm" >/dev/null 2>&1
  fi
done
exit 0
EORCLOCAL

chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
ok "rc.local fallback created"

# ============================================================
header "✅ CONFIGURATION COMPLETE"
echo ""
echo "📊 Summary:"
echo "   • CPU limit: ${CPU_LIMIT_PERCENT}% per VM (${CPU_COUNT} cores)"
echo "   • RAM limit: ~$((RAM_LIMIT_PER_VM_MB/1024))GB per VM"
echo "   • VMs configured: ${VM_COUNT}"
echo ""
ok "All done! VMs will auto-restart on crash or host reboot."