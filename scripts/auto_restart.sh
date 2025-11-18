#!/bin/bash
# ============================================================
# VM Limiter + HugePages Helper
# - CPU limits via systemd cgroups (CPUQuota)
# - RAM limits via libvirt (setmaxmem + setmem)
# - Optional HugePages pre-allocation before VM start
# - Autostart + monitor autorestart
#
# NOTE about HugePages:
# - Running VMs are NOT migrated to HugePages (that would require a restart).
# - If a VM is already running and using a lot of RAM, this script:
#     * applies CPU limits
#     * updates persistent RAM config
#     * DOES NOT touch HugePages for that running VM right now
# - HugePages are used on the next VM start (shutdown → start, or monitor restart).
# ============================================================

set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok(){ echo -e "${GREEN}✓ $1${NC}"; }
warn(){ echo -e "${YELLOW}⚠ $1${NC}"; }
err(){ echo -e "${RED}✗ $1${NC}"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}"; }

# ============================================================
# Root check (must be root as early as possible)
if [[ $(id -u) -ne 0 ]]; then
  err "Must run as root (sudo bash $0)"
fi

# ============================================================
# Configuration (edit these values as needed)
CPU_LIMIT_PERCENT=85     # CPU quota for all VMs (shared)
RAM_LIMIT_PERCENT=83     # Percentage of host RAM allowed for ALL VMs combined
MONITOR_INTERVAL=30      # Seconds between monitor checks
USE_HUGEPAGES=1          # 1 = ON (HugePages used on VM start), 0 = OFF

# ============================================================
header "1. Checking cgroup v2"

CGROUP_TYPE=$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo "unknown")

if [[ "$CGROUP_TYPE" != "cgroup2fs" ]]; then
  warn "cgroup v2 not detected! Enabling it in GRUB..."

  cp /etc/default/grub /etc/default/grub.backup

  if grep -q "systemd.unified_cgroup_hierarchy=1" /etc/default/grub; then
    ok "cgroup v2 parameter already present in GRUB"
  else
    sed -i 's/GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 systemd.unified_cgroup_hierarchy=1"/' /etc/default/grub
    ok "Added cgroup v2 kernel parameter to GRUB config"
  fi

  if command -v update-grub >/dev/null 2>&1; then
    update-grub
  elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  else
    err "Cannot find GRUB update command (update-grub or grub2-mkconfig)"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "⚠️  REBOOT REQUIRED to enable cgroup v2"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Run this script again after reboot:"
  echo "  sudo bash $0"
  echo ""
  read -p "Reboot now? [y/N] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
  else
    exit 0
  fi
else
  ok "cgroup v2 is active (cgroup2fs)"
fi

# ============================================================
header "2. Installing dependencies"

if command -v apt-get >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1
  apt-get install -y bc libvirt-clients >/dev/null 2>&1
else
  warn "apt-get not found; please make sure bc + libvirt-clients are installed manually"
fi

if ! command -v virsh >/dev/null 2>&1; then
  err "virsh not found. Install libvirt-clients/libvirt-tools first."
fi

systemctl is-active --quiet libvirtd || systemctl enable --now libvirtd
ok "libvirtd is active"

# ============================================================
header "3. Applying kernel memory tuning"

tee /etc/sysctl.d/99-memory-tuning.conf >/dev/null <<EOF
vm.swappiness=70
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF

sysctl --system >/dev/null
ok "Kernel memory tuning applied"

# ============================================================
header "4. Detecting VMs"

VM_LIST=$(virsh list --all --name | grep -v '^$' || true)
[[ -z "$VM_LIST" ]] && err "No VMs found via 'virsh list --all'"

VM_COUNT=$(echo "$VM_LIST" | wc -l)
ok "Found ${VM_COUNT} VM(s): $(echo $VM_LIST | tr '\n' ' ')"

# ============================================================
header "5. Calculating host resources"

CPU_COUNT=$(nproc)
RAM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_TOTAL_MB=$((RAM_TOTAL_KB/1024))
RAM_LIMIT_MB=$((RAM_TOTAL_MB*RAM_LIMIT_PERCENT/100))
RAM_LIMIT_PER_VM_MB=$((RAM_LIMIT_MB/VM_COUNT))

CPU_QUOTA_PERCENT=${CPU_LIMIT_PERCENT}

ok "Host: ${CPU_COUNT} core(s), ${RAM_TOTAL_MB}MB RAM total"
ok "Target limit per VM (theoretical): ~$((RAM_LIMIT_PER_VM_MB/1024))GB, ${CPU_LIMIT_PERCENT}% CPU share"

# ============================================================
header "6. INSTANT CPU LIMIT via systemd (no RAM limit here)"

QEMU_SCOPES=$(systemctl list-units --type=scope --all --state=active | \
               grep -iE "(qemu|machine)" | grep -v "machine.slice" | awk '{print $1}' || true)

if [[ -z "$QEMU_SCOPES" ]]; then
  warn "No active QEMU scopes found - CPU limits will be applied when VMs start"
else
  SCOPE_COUNT=$(echo "$QEMU_SCOPES" | wc -l)

  if [[ "$SCOPE_COUNT" -eq 1 ]]; then
    echo "📌 Single VM detected - applying CPU limit directly to its scope"
    SINGLE_SCOPE=$(echo "$QEMU_SCOPES" | head -n1)
    systemctl set-property "$SINGLE_SCOPE" \
      CPUQuota=${CPU_LIMIT_PERCENT}% 2>/dev/null && \
      ok "Instant CPU limit applied to $SINGLE_SCOPE" || \
      warn "Failed to apply CPU limit to $SINGLE_SCOPE"
  else
    echo "📌 Multiple VMs detected - applying CPU limit to machine.slice (shared)"
    systemctl set-property machine.slice \
      CPUQuota=${CPU_LIMIT_PERCENT}% 2>/dev/null && \
      ok "Instant CPU limit applied to machine.slice (all VMs share CPU)" || \
      warn "Failed to apply CPU limit to machine.slice"
  fi
fi

# ============================================================
header "7. PERSISTENT LIMITS via libvirt XML (survive reboot)"

for VM in $VM_LIST; do
  echo -e "\n🖥️  Configuring VM: $VM"

  # Ensure the VM is defined as persistent
  if ! virsh dominfo "$VM" 2>/dev/null | grep -q "Persistent:.*yes"; then
    virsh dumpxml "$VM" > "/tmp/${VM}.xml"
    virsh define "/tmp/${VM}.xml" && rm "/tmp/${VM}.xml"
    ok "Made VM persistent in libvirt"
  fi

  # Enable autostart
  virsh autostart "$VM" 2>/dev/null || warn "Autostart may already be enabled for $VM"

  # Update CPU limit in XML
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
  ok "Persistent CPU limit written to XML for $VM"

  # Set RAM limit in config (this may or may not apply immediately if VM is running)
  RAM_LIMIT_KB=$((RAM_LIMIT_PER_VM_MB * 1024))
  virsh setmaxmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null || true

  if virsh setmem "$VM" "${RAM_LIMIT_KB}" --config 2>/dev/null; then
    ok "Persistent RAM limit set for $VM (may take effect on next reboot if guest is running)"
  else
    warn "setmem failed for $VM (guest might be running or have different memory constraints)"
  fi

  # Start VM only if it's currently stopped
  if ! virsh domstate "$VM" 2>/dev/null | grep -q running; then
    # VM is powered off → we are allowed to prepare HugePages and then start it
    if [[ "$USE_HUGEPAGES" -eq 1 ]]; then
      VM_XML_MEM=$(virsh dumpxml "$VM" \
        | awk -F'[<>]' '/<memory unit='\''KiB'\''>/ {print $3; exit}')

      if [[ -n "$VM_XML_MEM" ]]; then
        PAGES=$(( VM_XML_MEM / 2048 ))  # 2MB per HugePage
        if echo "$PAGES" > /proc/sys/vm/nr_hugepages 2>/dev/null; then
          echo "[HugePages] Allocated $PAGES pages (for $VM)" | systemd-cat -t vm-monitor
          ok "HugePages reserved for $VM ($PAGES pages)"
        else
          echo "[HugePages] Failed to allocate $PAGES pages (for $VM)" | systemd-cat -t vm-monitor
          warn "Failed to allocate HugePages for $VM. VM will start without HugePages."
        fi
      else
        echo "[HugePages] Unable to read memory for $VM" | systemd-cat -t vm-monitor
        warn "Could not read memory from XML for HugePages calculation"
      fi
    fi

    if virsh start "$VM"; then
      ok "VM started: $VM"
    else
      warn "Could not start VM $VM (check libvirt logs for details)"
    fi
    sleep 5

    # Free unused HugePages after VM start (pages in use stay pinned)
    if [[ "$USE_HUGEPAGES" -eq 1 ]]; then
      echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
    fi

    # Apply instant CPU limit to the freshly started VM
    NEW_SCOPE=$(systemctl list-units --type=scope | grep -i "$VM" | awk '{print $1}' | head -n1)
    if [[ -n "$NEW_SCOPE" ]]; then
      systemctl set-property "$NEW_SCOPE" \
        CPUQuota=${CPU_LIMIT_PERCENT}% 2>/dev/null && \
        ok "Instant CPU limit applied to newly started VM scope: $NEW_SCOPE" || \
        warn "Failed to apply CPU limit to scope $NEW_SCOPE"
    fi
  else
    # VM is already running: DO NOT touch HugePages now (too risky with high RAM usage)
    warn "VM $VM is currently RUNNING. HugePages will only be used on the NEXT start/reboot."
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
ok "Systemd services created/enabled for all VMs"

# ============================================================
header "9. Creating VM monitor + CPU-limit reapply daemon"

MONITOR_SCRIPT="/usr/local/bin/vm-monitor.sh"
cat > "$MONITOR_SCRIPT" <<EOMONITOR
#!/bin/bash
# VM monitor: auto-restart + reapply CPU limits (+ optional HugePages)

CPU_QUOTA=${CPU_LIMIT_PERCENT}
USE_HUGEPAGES=${USE_HUGEPAGES}

while true; do
  for VM in \$(virsh list --all --name | grep -v '^$'); do
    if virsh dominfo "\$VM" 2>/dev/null | grep -q "Autostart:.*enable"; then
      if ! virsh domstate "\$VM" 2>/dev/null | grep -q running; then
        echo "[\$(date)] VM \$VM is down, starting..." | systemd-cat -t vm-monitor

        if [[ "\$USE_HUGEPAGES" -eq 1 ]]; then
          VM_XML_MEM=\$(virsh dumpxml "\$VM" | awk -F'[<>]' '/<memory unit='"'"'KiB'"'"'>/ {print \$3; exit}')
          if [[ -n "\$VM_XML_MEM" ]]; then
            PAGES=\$(( VM_XML_MEM / 2048 ))
            if echo "\$PAGES" > /proc/sys/vm/nr_hugepages 2>/dev/null; then
              echo "[\$(date)] [HugePages] Allocated \$PAGES pages for \$VM" | systemd-cat -t vm-monitor
            else
              echo "[\$(date)] [HugePages] Failed to allocate \$PAGES pages for \$VM" | systemd-cat -t vm-monitor
            fi
          else
            echo "[\$(date)] [HugePages] Unable to read memory for \$VM" | systemd-cat -t vm-monitor
          fi
        fi

        virsh start "\$VM" 2>/dev/null
        sleep 5

        if [[ "\$USE_HUGEPAGES" -eq 1 ]]; then
          echo 0 > /proc/sys/vm/nr_hugepages 2>/dev/null || true
        fi

        # Reapply CPU limit
        SCOPE=\$(systemctl list-units --type=scope | grep -i "\$VM" | awk '{print \$1}' | head -n1)
        if [[ -n "\$SCOPE" ]]; then
          systemctl set-property "\$SCOPE" \
            CPUQuota=\${CPU_QUOTA}% 2>/dev/null
          echo "[\$(date)] Reapplied CPU limit to \$VM (scope \$SCOPE)" | systemd-cat -t vm-monitor
        fi
      fi
    fi
  done
  sleep ${MONITOR_INTERVAL}
done
EOMONITOR

chmod +x "$MONITOR_SCRIPT"
ok "Monitor script created at ${MONITOR_SCRIPT}"

# ============================================================
header "10. Creating monitor systemd service"

cat > /etc/systemd/system/vm-monitor.service <<EOF
[Unit]
Description=VM Monitor + CPU Limit Reapply (+ HugePages helper)
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
# Fallback: VM startup is handled by libvirt + vm-monitor.service
sleep 1
exit 0
EORCLOCAL

chmod +x /etc/rc.local
systemctl enable rc-local 2>/dev/null || true
ok "rc.local fallback created/enabled"

# ============================================================
header "✅ CONFIGURATION COMPLETE"
echo ""
echo "📊 Applied Limits / Settings:"
echo "   • CPU: ${CPU_LIMIT_PERCENT}% (systemd CPUQuota, shared across VMs)"
echo "   • Target RAM per VM: ~${RAM_LIMIT_PER_VM_MB}MB (~${RAM_LIMIT_PERCENT}% of host RAM / ${VM_COUNT} VM)"
echo "   • HugePages: $( [[ "$USE_HUGEPAGES" -eq 1 ]] && echo ENABLED || echo DISABLED )"
echo ""
echo "ℹ️  Running VMs:"
for VM in $VM_LIST; do
  if virsh domstate "$VM" 2>/dev/null | grep -q running; then
    echo "   - $VM is RUNNING now:"
    echo "     • CPU limit: applied via cgroup"
    echo "     • RAM limit: in config (may require reboot to fully enforce)"
    echo "     • HugePages: will be used on NEXT start (not modified while running)"
  fi
done
echo ""
echo "🔄 Autorestart layers:"
echo "   1. virsh autostart for each VM"
echo "   2. systemd per-VM services (libvirt-vm-<name>.service)"
echo "   3. vm-monitor.service (checks every ${MONITOR_INTERVAL}s, restarts VMs, reapplies CPU limits, handles HugePages on start)"
echo "   4. rc.local fallback (lightweight, does nothing major)"
