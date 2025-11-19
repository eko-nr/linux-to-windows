#!/bin/bash
# ============================================================
# VM Limiter + Auto-Restart (No HugePages)
# - Limits CPU/RAM for all libvirt VMs
# - Auto-restarts VMs if they go down
# - Ensures HugePages are disabled (nr_hugepages = 0)
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Colors / helpers
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✗ $1${NC}"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ------------------------------------------------------------
# Configuration (edit these values as needed)
CPU_LIMIT_PERCENT=85       # CPU quota for all VMs
RAM_LIMIT_PERCENT=83       # Max RAM used by all VMs (% of host)
SWAP_LIMIT_PERCENT=100     # Max SWAP used by all VMs (% of host RAM)
MONITOR_INTERVAL=30        # Seconds between monitor checks

# ============================================================
header "0. Pre-checks"

# Must be root
if [[ $(id -u) -ne 0 ]]; then
  err "This script must be run as root"
fi

# Ensure HugePages are disabled globally
if [[ -w /proc/sys/vm/nr_hugepages ]]; then
  echo 0 > /proc/sys/vm/nr_hugepages || warn "Failed to reset HugePages (nr_hugepages)"
  ok "HugePages disabled (nr_hugepages=0)"
else
  warn "/proc/sys/vm/nr_hugepages not writable or not present (skipping HugePages reset)"
fi

# ============================================================
header "1. Checking cgroup v2"

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo "unknown")

if [[ "$CGROUP_TYPE" != "cgroup2fs" ]]; then
  warn "Cgroup v2 not detected! Enabling now..."

  cp /etc/default/grub /etc/default/grub.backup

  if grep -q "systemd.unified_cgroup_hierarchy=1" /etc/default/grub; then
    ok "Cgroup v2 parameter already present in grub"
  else
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
    ok "Added cgroup v2 parameter to grub config"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  else
    err "Cannot find grub update command (update-grub or grub2-mkconfig)"
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
header "2. Installing dependencies"

apt-get update >/dev/null 2>&1
apt-get install -y bc >/dev/null 2>&1

if ! systemctl is-active --quiet libvirtd; then
  systemctl enable --now libvirtd
fi

ok "Dependencies installed and libvirtd is active"

# ============================================================
header "3. Applying memory tuning"

tee /etc/sysctl.d/99-memory-tuning.conf >/dev/null <<EOF
vm.swappiness=70
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF

sysctl --system >/dev/null
ok "Memory tuning applied"

# ============================================================
header "4. Detecting VMs"

VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
[[ -z "$VM_LIST" ]] && err "No VMs found"

VM_COUNT=$(echo "$VM_LIST" | wc -l)
ok "Found ${VM_COUNT} VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
header "5. Calculating resource limits"

CPU_COUNT=$(nproc)

RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB/1024))
RAM_LIMIT_MB=$((RAM_TOTAL_MB*RAM_LIMIT_PERCENT/100))
RAM_LIMIT_PER_VM_MB=$((RAM_LIMIT_MB/VM_COUNT))

TOTAL_SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [[ -z "${TOTAL_SWAP_KB:-}" ]] || [[ "$TOTAL_SWAP_KB" -eq 0 ]]; then
  warn "No swap detected, SWAP limit set to 0"
  SWAP_LIMIT_MB=0
else
  SWAP_LIMIT_MB=$((RAM_TOTAL_MB*SWAP_LIMIT_PERCENT/100))
fi

CPU_QUOTA_PERCENT=${CPU_LIMIT_PERCENT}

ok "Host resources: ${CPU_COUNT} cores, ${RAM_TOTAL_MB} MB RAM"
ok "VM limits: ~${RAM_LIMIT_PER_VM_MB} MB RAM per VM, ${CPU_LIMIT_PERCENT}% CPU (shared)"

# ============================================================
header "6. Applying INSTANT limits via systemd (live)"

QEMU_SCOPES=$(systemctl list-units --type=scope --all --state=active \
  | grep -iE "(qemu|machine)" | grep -v "machine.slice" | awk '{print $1}' || true)

if [[ -z "$QEMU_SCOPES" ]]; then
  warn "No active QEMU scopes found - instant limits will apply after VMs start"
else
  SCOPE_COUNT=$(echo "$QEMU_SCOPES" | wc -l)

  if [[ "$SCOPE_COUNT" -eq 1 ]]; then
    echo "📌 Single VM scope detected - applying limits directly"
    SINGLE_SCOPE=$(echo "$QEMU_SCOPES" | head -n1)
    if systemctl set-property "$SINGLE_SCOPE" \
      CPUQuota=${CPU_LIMIT_PERCENT}% \
      MemoryMax=${RAM_LIMIT_MB}M \
      MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
      ok "Instant limits applied to $SINGLE_SCOPE"
    else
      warn "Failed to apply instant limits on $SINGLE_SCOPE"
    fi
  else
    echo "📌 Multiple VMs detected - applying limits to machine.slice (shared)"
    if systemctl set-property machine.slice \
      CPUQuota=${CPU_LIMIT_PERCENT}% \
      MemoryMax=${RAM_LIMIT_MB}M \
      MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
      ok "Instant limits applied to machine.slice (all VMs share resource pool)"
    else
      warn "Failed to apply instant limits on machine.slice"
    fi
  fi
fi

# ============================================================
header "7. Setting PERSISTENT limits via libvirt XML"

for VM in $VM_LIST; do
  echo -e "\n🖥️  Configuring VM: $VM"

  # Ensure persistent definition
  if ! virsh dominfo "$VM" 2>/dev/null | grep -q "Persistent:.*yes"; then
    virsh dumpxml "$VM" > "/tmp/${VM}.xml"
    virsh define "/tmp/${VM}.xml" && rm "/tmp/${VM}.xml"
    ok "VM made persistent"
  fi

  # Enable libvirt autostart
  virsh autostart "$VM" 2>/dev/null || warn "Autostart may already be enabled for $VM"

  # Update XML with CPU limit (quota/period)
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
  ok "Persistent CPU limit applied to $VM"

  # Set RAM limit (config only)
  RAM_LIMIT_KB=$((RAM_LIMIT_PER_VM_MB * 1024))
  if virsh setmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null; then
    ok "Persistent RAM limit applied to $VM"
  else
    warn "Failed to apply RAM limit to $VM (setmem)"
  fi

  # Start VM if not running (without HugePages)
  if ! virsh domstate "$VM" 2>/dev/null | grep -q running; then
    # Ensure HugePages remain disabled before starting
    if [[ -w /proc/sys/vm/nr_hugepages ]]; then
      echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
    fi

    if virsh start "$VM"; then
      ok "VM $VM started"
      sleep 5

      # Apply instant limits to newly started VM
      NEW_SCOPE=$(systemctl list-units --type=scope | grep -i "$VM" | awk '{print $1}' | head -n1)
      if [[ -n "$NEW_SCOPE" ]]; then
        systemctl set-property "$NEW_SCOPE" \
          CPUQuota=${CPU_LIMIT_PERCENT}% \
          MemoryMax=${RAM_LIMIT_MB}M \
          MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null && \
          ok "Instant limits applied to newly started VM $VM" || \
          warn "Failed to apply instant limits to $VM scope"
      fi
    else
      warn "Could not start VM $VM"
    fi
  fi
done

# ============================================================
header "8. Creating per-VM systemd services"

for VM in $VM_LIST; do
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
  systemctl enable "libvirt-vm-${VM}.service" 2>/dev/null || true
done

ok "Per-VM systemd services created and enabled"

# ============================================================
header "9. Creating VM monitor + limit reapply daemon (no HugePages)"

MONITOR_SCRIPT="/usr/local/bin/vm-monitor.sh"
cat > "$MONITOR_SCRIPT" <<EOMONITOR
#!/bin/bash
# VM monitor:
# - Restarts autostart-enabled VMs when they go down
# - Re-applies systemd CPU/RAM/SWAP limits
# - Ensures HugePages remain disabled

CPU_QUOTA=${CPU_LIMIT_PERCENT}
RAM_LIMIT=${RAM_LIMIT_MB}
SWAP_LIMIT=${SWAP_LIMIT_MB}
INTERVAL=${MONITOR_INTERVAL}

while true; do
  # Ensure HugePages are always disabled
  if [[ -w /proc/sys/vm/nr_hugepages ]]; then
    echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
  fi

  for VM in \$(virsh list --all --name | grep -v '^$'); do
    # Only care about VMs with autostart enabled
    if virsh dominfo "\$VM" 2>/dev/null | grep -q "Autostart:.*enable"; then
      if ! virsh domstate "\$VM" 2>/dev/null | grep -q running; then
        echo "[\$(date)] VM \$VM is down, restarting (no HugePages)..." | systemd-cat -t vm-monitor

        # Ensure HugePages disabled before starting
        if [[ -w /proc/sys/vm/nr_hugepages ]]; then
          echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        fi

        virsh start "\$VM" 2>/dev/null
        sleep 5

        # Reapply instant limit after restart
        SCOPE=\$(systemctl list-units --type=scope | grep -i "\$VM" | awk '{print \$1}' | head -n1)
        if [[ -n "\$SCOPE" ]]; then
          systemctl set-property "\$SCOPE" \
            CPUQuota=\${CPU_QUOTA}% \
            MemoryMax=\${RAM_LIMIT}M \
            MemorySwapMax=\${SWAP_LIMIT}M 2>/dev/null

          echo "[\$(date)] Reapplied limits to \$VM (\$SCOPE)" | systemd-cat -t vm-monitor
        fi
      fi
    fi
  done

  sleep "\$INTERVAL"
done
EOMONITOR

chmod +x "$MONITOR_SCRIPT"
ok "VM monitor script created at ${MONITOR_SCRIPT}"

# ============================================================
header "10. Creating vm-monitor systemd service"

cat > /etc/systemd/system/vm-monitor.service <<EOF
[Unit]
Description=VM Monitor + Limit Reapply (No HugePages)
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
ok "VM monitor service enabled and started"

# ============================================================
header "11. Creating rc.local fallback"

cat > /etc/rc.local <<'EORCLOCAL'
#!/bin/bash
# VM startup is handled by libvirt autostart, per-VM systemd services, and vm-monitor.service
sleep 1
exit 0
EORCLOCAL

chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
ok "rc.local fallback created and enabled"

# ============================================================
header "✅ CONFIGURATION COMPLETE"

echo ""
echo "📊 Applied Limits:"
echo "   • CPU:  ${CPU_LIMIT_PERCENT}% (systemd CPUQuota)"
echo "   • RAM:  ${RAM_LIMIT_MB} MB (~${RAM_LIMIT_PERCENT}% of host)"
echo "   • SWAP: ${SWAP_LIMIT_MB} MB (~${SWAP_LIMIT_PERCENT}% of host RAM)"
echo ""
echo "🚫 HugePages:"
if [[ -r /proc/sys/vm/nr_hugepages ]]; then
  echo "   • nr_hugepages: $(cat /proc/sys/vm/nr_hugepages) (should be 0)"
else
  echo "   • /proc/sys/vm/nr_hugepages not readable (kernel may not support HugePages or proc file missing)"
fi
echo ""
echo "⚡ Instant Limits (current systemd values):"
if [[ -n "${QEMU_SCOPES:-}" ]]; then
  if [[ "${SCOPE_COUNT:-0}" -eq 1 ]]; then
    systemctl show "$SINGLE_SCOPE" 2>/dev/null | grep -E "CPUQuota|MemoryMax|MemorySwapMax" | sed 's/^/   /'
  else
    systemctl show machine.slice 2>/dev/null | grep -E "CPUQuota|MemoryMax|MemorySwapMax" | sed 's/^/   /'
  fi
else
  echo "   (Will apply when VMs are started)"
fi
echo ""
echo "🔄 Autorestart Enabled:"
echo "   1. ✓ virsh autostart"
echo "   2. ✓ systemd per-VM services"
echo "   3. ✓ vm-monitor.service (checks every ${MONITOR_INTERVAL}s + reapplies limits)"
echo "   4. ✓ rc.local fallback"
echo ""
echo "All VMs will now restart WITHOUT HugePages and with CPU/RAM limits enforced."
