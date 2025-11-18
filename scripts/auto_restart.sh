#!/bin/bash
# ============================================================
# VM Limiter: Instant + Persistent + Autorestart (Revised)
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✗ $1${NC}"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ============================================================
# Root check (paling awal supaya grub/sysctl aman)
if [[ $(id -u) -ne 0 ]]; then
  err "Must run as root (sudo bash $0)"
fi

# ============================================================
# Configuration (edit these values as needed)
CPU_LIMIT_PERCENT=85     # persen CPU untuk semua VM
RAM_LIMIT_PERCENT=83     # persen RAM host yang boleh dipakai VM
SWAP_LIMIT_PERCENT=100   # persen RAM (bukan swap) untuk MemorySwapMax
MONITOR_INTERVAL=30      # detik
USE_HUGEPAGES=0          # 0 = OFF (disarankan), 1 = ON

# ============================================================
header "1. Checking cgroup v2"

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo "unknown")

if [[ "$CGROUP_TYPE" != "cgroup2fs" ]]; then
  warn "Cgroup v2 not detected! Enabling now..."

  cp /etc/default/grub /etc/default/grub.backup

  if grep -q "systemd.unified_cgroup_hierarchy=1" /etc/default/grub; then
    ok "Cgroup v2 parameter already in grub"
  else
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
    ok "Added cgroup v2 to grub config"
  fi

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
header "2. Installing dependencies"

if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1
  # bc + virsh client
  apt-get install -y bc >/dev/null 2>&1
else
  warn "apt-get not found, please install bc manually"
fi

# pastikan virsh ada
if ! command -v virsh >/dev/null 2>&1; then
  err "virsh not found. Install libvirt-clients/libvirt-tools terlebih dahulu."
fi

systemctl is-active --quiet libvirtd || systemctl enable --now libvirtd
ok "System ready"

# ============================================================
header "3. Applying memory tuning"

tee /etc/sysctl.d/99-memory-tuning.conf >/dev/null <<EOF
vm.swappiness=70
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF

sysctl --system >/dev/null
ok "Memory tuning applied (swappiness=70)"

# ============================================================
header "4. Detecting VMs"

VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
[[ -z "$VM_LIST" ]] && err "No VMs found"
VM_COUNT=$(echo "$VM_LIST" | wc -l)
ok "Found ${VM_COUNT} VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
header "5. Calculating resources"

CPU_COUNT=$(nproc)
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB/1024))
RAM_LIMIT_MB=$((RAM_TOTAL_MB*RAM_LIMIT_PERCENT/100))
RAM_LIMIT_PER_VM_MB=$((RAM_LIMIT_MB/VM_COUNT))

TOTAL_SWAP_KB=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [[ -z "${TOTAL_SWAP_KB}" ]] || [[ "${TOTAL_SWAP_KB}" -eq 0 ]]; then
  warn "No swap detected, SWAP limit will not be enforced by systemd"
  SWAP_LIMIT_MB=0
else
  SWAP_LIMIT_MB=$((RAM_TOTAL_MB*SWAP_LIMIT_PERCENT/100))
fi

CPU_QUOTA_PERCENT=${CPU_LIMIT_PERCENT}

ok "Host: ${CPU_COUNT} cores, ${RAM_TOTAL_MB}MB RAM"
ok "Limit per VM: ~$((RAM_LIMIT_PER_VM_MB/1024))GB RAM, ${CPU_LIMIT_PERCENT}% CPU"

# ============================================================
header "6. INSTANT LIMIT via systemd (live, no restart needed)"

QEMU_SCOPES=$(systemctl list-units --type=scope --all --state=active | grep -iE "(qemu|machine)" | grep -v "machine.slice" | awk '{print $1}' || true)

if [[ -z "$QEMU_SCOPES" ]]; then
  warn "No active QEMU scopes found - will apply after VM starts"
else
  SCOPE_COUNT=$(echo "$QEMU_SCOPES" | wc -l)

  if [[ "$SCOPE_COUNT" -eq 1 ]]; then
    echo "📌 Single VM - applying direct limit"
    SINGLE_SCOPE=$(echo "$QEMU_SCOPES" | head -n1)
    if [[ "$SWAP_LIMIT_MB" -gt 0 ]]; then
      systemctl set-property "$SINGLE_SCOPE" \
        CPUQuota=${CPU_LIMIT_PERCENT}% \
        MemoryMax=${RAM_LIMIT_MB}M \
        MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null && \
        ok "INSTANT limit applied to $SINGLE_SCOPE" || warn "Failed to apply instant limit"
    else
      systemctl set-property "$SINGLE_SCOPE" \
        CPUQuota=${CPU_LIMIT_PERCENT}% \
        MemoryMax=${RAM_LIMIT_MB}M 2>/dev/null && \
        ok "INSTANT limit applied to $SINGLE_SCOPE (no swap limit)" || warn "Failed to apply instant limit"
    fi

  else
    echo "📌 Multiple VMs - applying to machine.slice (dynamic sharing)"
    if [[ "$SWAP_LIMIT_MB" -gt 0 ]]; then
      systemctl set-property machine.slice \
        CPUQuota=${CPU_LIMIT_PERCENT}% \
        MemoryMax=${RAM_LIMIT_MB}M \
        MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null && \
        ok "INSTANT limit applied to machine.slice (all VMs share)" || warn "Failed to apply instant limit"
    else
      systemctl set-property machine.slice \
        CPUQuota=${CPU_LIMIT_PERCENT}% \
        MemoryMax=${RAM_LIMIT_MB}M 2>/dev/null && \
        ok "INSTANT limit applied to machine.slice (no swap limit)" || warn "Failed to apply instant limit"
    fi
  fi
fi

# ============================================================
header "7. PERSISTENT LIMIT via libvirt XML (survives reboot)"

for VM in $VM_LIST; do
  echo -e "\n🖥️  Configuring: $VM"

  # Make persistent
  if ! virsh dominfo "$VM" 2>/dev/null | grep -q "Persistent:.*yes"; then
    virsh dumpxml "$VM" > "/tmp/${VM}.xml"
    virsh define "/tmp/${VM}.xml" && rm "/tmp/${VM}.xml"
    ok "Made persistent"
  fi

  # Enable autostart
  virsh autostart "$VM" 2>/dev/null || warn "Autostart failed (may already be set)"

  # Update XML with CPU limit
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
  ok "Persistent CPU limit set"

  # Set RAM limit (maxmem + mem)
  RAM_LIMIT_KB=$((RAM_LIMIT_PER_VM_MB * 1024))
  virsh setmaxmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null || true
  if virsh setmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null; then
    ok "Persistent RAM limit set"
  else
    warn "RAM setmem failed (VM mem mungkin lebih besar dari host limit atau guest sudah jalan)"
  fi

  # Start if not running
  if ! virsh domstate "$VM" 2>/dev/null | grep -q running; then

    # Optional: HugePages (default OFF via USE_HUGEPAGES)
    if [[ "$USE_HUGEPAGES" -eq 1 ]]; then
      VM_XML_MEM=$(virsh dumpxml "$VM" \
        | awk -F'[<>]' '/<memory unit='\''KiB'\''>/ {print $3; exit}')
      if [[ -n "$VM_XML_MEM" ]]; then
        PAGES=$(( VM_XML_MEM / 2048 ))
        echo "$PAGES" > /proc/sys/vm/nr_hugepages || true
        echo "[HugePages] Allocated $PAGES pages (for $VM)" | systemd-cat -t vm-monitor
      else
        echo "[HugePages] Unable to read memory for $VM" | systemd-cat -t vm-monitor
      fi
    fi

    if virsh start "$VM"; then
      ok "VM started"
    else
      warn "Could not start VM"
    fi
    sleep 5

    # Optional: free unused HugePages (in-use pages tetap kepakai)
    if [[ "$USE_HUGEPAGES" -eq 1 ]]; then
      echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
    fi

    # Apply instant limit to newly started VM
    NEW_SCOPE=$(systemctl list-units --type=scope | grep -i "$VM" | awk '{print $1}' | head -n1)
    if [[ -n "$NEW_SCOPE" ]]; then
      if [[ "$SWAP_LIMIT_MB" -gt 0 ]]; then
        systemctl set-property "$NEW_SCOPE" \
          CPUQuota=${CPU_LIMIT_PERCENT}% \
          MemoryMax=${RAM_LIMIT_MB}M \
          MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null && \
          ok "Instant limit applied to newly started VM" || true
      else
        systemctl set-property "$NEW_SCOPE" \
          CPUQuota=${CPU_LIMIT_PERCENT}% \
          MemoryMax=${RAM_LIMIT_MB}M 2>/dev/null && \
          ok "Instant limit applied to newly started VM (no swap limit)" || true
      fi
    fi
  fi
done

# ============================================================
header "8. Creating systemd per-VM services"

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
  systemctl enable "libvirt-vm-${VM}.service" 2>/dev/null
done
ok "Systemd services created for all VMs"

# ============================================================
header "9. Creating VM monitor + limit reapply daemon"

MONITOR_SCRIPT="/usr/local/bin/vm-monitor.sh"
cat > "$MONITOR_SCRIPT" <<EOMONITOR
#!/bin/bash
# VM monitor: auto-restart + reapply limits

CPU_QUOTA=${CPU_LIMIT_PERCENT}
RAM_LIMIT=${RAM_LIMIT_MB}
SWAP_LIMIT=${SWAP_LIMIT_MB}
USE_HUGEPAGES=${USE_HUGEPAGES}

while true; do
  for VM in \$(virsh list --all --name | grep -v '^$'); do
    if virsh dominfo "\$VM" 2>/dev/null | grep -q "Autostart:.*enable"; then
      if ! virsh domstate "\$VM" 2>/dev/null | grep -q running; then
        echo "[\$(date)] VM \$VM is down, restarting..." | systemd-cat -t vm-monitor

        if [[ "\$USE_HUGEPAGES" -eq 1 ]]; then
          VM_XML_MEM=\$(virsh dumpxml "\$VM" | awk -F'[<>]' '/<memory unit='"'"'KiB'"'"'>/ {print \$3; exit}')
          if [[ -n "\$VM_XML_MEM" ]]; then
            PAGES=\$(( VM_XML_MEM / 2048 ))
            echo "\$PAGES" > /proc/sys/vm/nr_hugepages
            echo "[\$(date)] [HugePages] Allocated \$PAGES pages for \$VM" | systemd-cat -t vm-monitor
          else
            echo "[\$(date)] [HugePages] Unable to read memory for \$VM" | systemd-cat -t vm-monitor
          fi
        fi

        virsh start "\$VM" 2>/dev/null
        sleep 5

        if [[ "\$USE_HUGEPAGES" -eq 1 ]]; then
          echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        fi

        # Reapply instant limit after restart
        SCOPE=\$(systemctl list-units --type=scope | grep -i "\$VM" | awk '{print \$1}' | head -n1)
        if [[ -n "\$SCOPE" ]]; then
          if [[ "\$SWAP_LIMIT" -gt 0 ]]; then
            systemctl set-property "\$SCOPE" \
              CPUQuota=\${CPU_QUOTA}% \
              MemoryMax=\${RAM_LIMIT}M \
              MemorySwapMax=\${SWAP_LIMIT}M 2>/dev/null
          else
            systemctl set-property "\$SCOPE" \
              CPUQuota=\${CPU_QUOTA}% \
              MemoryMax=\${RAM_LIMIT}M 2>/dev/null
          fi
          echo "[\$(date)] Reapplied limits to \$VM" | systemd-cat -t vm-monitor
        fi
      fi
    fi
  done
  sleep ${MONITOR_INTERVAL}
done
EOMONITOR

chmod +x "$MONITOR_SCRIPT"
ok "Monitor script created"

# ============================================================
header "10. Creating monitor systemd service"

cat > /etc/systemd/system/vm-monitor.service <<EOF
[Unit]
Description=VM Monitor + Limit Reapply
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
header "11. Creating rc.local fallback"

cat > /etc/rc.local <<'EORCLOCAL'
#!/bin/bash
# Do nothing, VM starts handled by libvirt + vm-monitor.service
sleep 1
exit 0
EORCLOCAL

chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
ok "rc.local fallback created"

# ============================================================
header "✅ CONFIGURATION COMPLETE"
echo ""
echo "📊 Applied Limits:"
echo "   • CPU: ${CPU_LIMIT_PERCENT}% (systemd CPUQuota)"
echo "   • RAM: ${RAM_LIMIT_MB}MB (~${RAM_LIMIT_PERCENT}%)"
echo "   • SWAP: ${SWAP_LIMIT_MB}MB (~${SWAP_LIMIT_PERCENT}%)"
echo ""
echo "⚡ Instant Limits (active NOW):"
if [[ -n "${QEMU_SCOPES:-}" ]]; then
  if [[ "${SCOPE_COUNT:-0}" -eq 1 ]]; then
    systemctl show "$SINGLE_SCOPE" 2>/dev/null | grep -E "CPUQuota|MemoryMax|MemorySwapMax" | sed 's/^/   /'
  else
    systemctl show machine.slice 2>/dev/null | grep -E "CPUQuota|MemoryMax|MemorySwapMax" | sed 's/^/   /'
  fi
else
  echo "   (Will apply when VMs start)"
fi
echo ""
echo "🔄 Autorestart Enabled:"
echo "   1. ✓ virsh autostart"
echo "   2. ✓ systemd per-VM services"
echo "   3. ✓ VM monitor (checks every ${MONITOR_INTERVAL}s + reapplies limits)"
echo "   4. ✓ rc.local fallback"
