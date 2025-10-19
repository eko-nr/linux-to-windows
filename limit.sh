#!/bin/bash--------
# Section 1: Dependencies
sudo apt-get install -y bc >/dev/null 2>&1

# --------------------------------------------------------------
# Section 2: Memory Optimization (Swap & Kernel Tuning)

sudo tee /etc/sysctl.d/99-memory-tuning.conf >/dev/null <<'EOF'
vm.swappiness=70
vm.vfs_cache_pressure=50
vm.dirty_ratio=15
vm.dirty_background_ratio=5
EOF

sudo sysctl --system >/dev/null
echo "✅ Memory tuning applied:"
sysctl vm.swappiness vm.vfs_cache_pressure vm.dirty_ratio vm.dirty_background_ratio
echo ""

# --------------------------------------------------------------
# Section 3: Resource Limiting for QEMU VMs
read -p "Enter maximum CPU usage percentage [default: 88]: " CPU_PCT
CPU_PCT=${CPU_PCT:-88}

read -p "Enter maximum RAM usage percentage [default: 88]: " RAM_PCT
RAM_PCT=${RAM_PCT:-88}

read -p "Enter maximum SWAP usage percentage [default: 100]: " SWAP_PCT
SWAP_PCT=${SWAP_PCT:-100}

echo ""
echo "Applying ${CPU_PCT}% CPU and ${RAM_PCT}% RAM limits to all QEMU VMs"
echo "====================================================================="

HOST_CPUS=$(nproc)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in kB
TOTAL_MEM_MB=$((TOTAL_MEM / 1024))

echo "ℹ️  Host has ${HOST_CPUS} CPU cores and ${TOTAL_MEM_MB} MB RAM"

MEM_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$RAM_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')

TOTAL_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ -z "$TOTAL_SWAP" ] || [ "$TOTAL_SWAP" -eq 0 ]; then
  echo "⚠️  No swap detected on the host, setting swap limit to 0."
  SWAP_LIMIT_MB=0
else
  SWAP_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$SWAP_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')
fi

SYSTEMD_CPU_QUOTA=$(awk -v host="$HOST_CPUS" -v pct="$CPU_PCT" 'BEGIN { printf "%.0f", host * pct }')

echo "➡️  CPU Limit: ${SYSTEMD_CPU_QUOTA}% (${CPU_PCT}% of ${HOST_CPUS} cores)"
echo "➡️  RAM Limit: ${MEM_LIMIT_MB} MB (${RAM_PCT}% of ${TOTAL_MEM_MB} MB)"
echo "➡️  SWAP Limit: ${SWAP_LIMIT_MB} MB (${SWAP_PCT}% of host RAM)"
echo ""

QEMU_SCOPES=$(systemctl list-units --type=scope --all --state=active | grep -iE "(qemu|machine)" | grep -v "machine.slice" | awk '{print $1}')

if [ -z "$QEMU_SCOPES" ]; then
  echo "❌ No active QEMU VM scopes found!"
  echo "   Make sure VMs are running and managed by systemd."
  echo ""
  echo "   Try: systemctl list-units --type=scope | grep -i qemu"
  exit 1
fi

VM_COUNT=$(echo "$QEMU_SCOPES" | wc -l)
echo "🔍 Found ${VM_COUNT} active QEMU VM(s):"
echo "$QEMU_SCOPES" | sed 's/^/   - /'
echo ""

if [ "$VM_COUNT" -eq 1 ]; then
  echo "📌 Strategy: Single VM detected - applying direct limit (full ${CPU_PCT}%)"
  echo ""
  SINGLE_VM=$(echo "$QEMU_SCOPES" | head -n1)
  echo "⚙️  Applying limits to: $SINGLE_VM"
  if sudo systemctl set-property "$SINGLE_VM" \
    CPUQuota=${SYSTEMD_CPU_QUOTA}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
    echo "   ✅ Success! VM can use up to ${CPU_PCT}% of host resources"
  else
    echo "   ❌ Failed to apply limits"
    exit 1
  fi
  echo ""
  echo "🔍 Verifying applied limits:"
  systemctl show "$SINGLE_VM" | grep -E "CPUQuota|MemoryMax|MemorySwapMax"
else
  echo "📌 Strategy: Multiple VMs detected - using parent slice for dynamic sharing"
  echo "   → All VMs will share ${CPU_PCT}% CPU and ${RAM_PCT}% RAM dynamically"
  echo "   → Idle VMs will release resources to busy ones automatically"
  echo ""
  echo "⚙️  Applying limits to machine.slice (parent cgroup)..."
  if sudo systemctl set-property machine.slice \
    CPUQuota=${SYSTEMD_CPU_QUOTA}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
    echo "   ✅ Success! All ${VM_COUNT} VMs share resources dynamically"
  else
    echo "   ❌ Failed to apply limits to machine.slice"
    exit 1
  fi
  echo ""
  echo "🔍 Verifying parent slice limits:"
  systemctl show machine.slice | grep -E "CPUQuota|MemoryMax|MemorySwapMax"
  echo ""
  echo "📊 Active VMs under this limit:"
  echo "$QEMU_SCOPES" | sed 's/^/   - /'
fi

echo ""
echo "====================================================================="
echo "✅ Done! Resource limits and memory tuning applied successfully."
echo ""
echo "💡 Summary:"
echo "   • vm.swappiness = 70 → moderately aggressive swap usage"
echo "   • vm.vfs_cache_pressure = 50 → keeps filesystem cache longer"
echo "   • dirty_ratio/background_ratio → controls disk writeback timing"
echo "====================================================================="
