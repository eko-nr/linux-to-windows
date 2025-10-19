#!/bin/bash
# --- Dependencies ---
sudo apt-get install -y bc >/dev/null 2>&1

# --- Prompt user for inputs ---
read -p "Enter maximum CPU usage percentage [default: 88]: " CPU_PCT
CPU_PCT=${CPU_PCT:-88}

read -p "Enter maximum RAM usage percentage [default: 88]: " RAM_PCT
RAM_PCT=${RAM_PCT:-88}

read -p "Enter maximum SWAP usage percentage [default: 100]: " SWAP_PCT
SWAP_PCT=${SWAP_PCT:-100}

echo ""
echo "Applying ${CPU_PCT}% CPU and ${RAM_PCT}% RAM limits to ALL QEMU VMs"
echo "====================================================================="

# --- Detect host resources ---
HOST_CPUS=$(nproc)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in kB
TOTAL_MEM_MB=$((TOTAL_MEM / 1024))

echo "ℹ️  Host has ${HOST_CPUS} CPU cores and ${TOTAL_MEM_MB} MB RAM"

# --- Calculate limits based on HOST resources ---
MEM_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$RAM_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')

# Calculate swap limit based on HOST total RAM
TOTAL_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ -z "$TOTAL_SWAP" ] || [ "$TOTAL_SWAP" -eq 0 ]; then
  echo "⚠️  No swap detected on host, setting swap limit to 0."
  SWAP_LIMIT_MB=0
else
  SWAP_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$SWAP_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')
fi

# Calculate CPU quota for systemd (percentage * host cores)
SYSTEMD_CPU_QUOTA=$(awk -v host="$HOST_CPUS" -v pct="$CPU_PCT" 'BEGIN { printf "%.0f", host * pct }')

echo "➡️  CPU Limit: ${SYSTEMD_CPU_QUOTA}% (${CPU_PCT}% of ${HOST_CPUS} cores)"
echo "➡️  RAM Limit: ${MEM_LIMIT_MB} MB (${RAM_PCT}% of ${TOTAL_MEM_MB} MB)"
echo "➡️  SWAP Limit: ${SWAP_LIMIT_MB} MB (${SWAP_PCT}% of host RAM)"
echo ""

# --- Find all QEMU systemd scopes ---
QEMU_SCOPES=$(systemctl list-units --type=scope --all --state=active | grep -iE "(qemu|machine)" | grep -v "machine.slice" | awk '{print $1}')

if [ -z "$QEMU_SCOPES" ]; then
  echo "❌ No active QEMU VM scopes found!"
  echo "   Make sure VMs are running and managed by systemd."
  echo ""
  echo "   Try: systemctl list-units --type=scope | grep -i qemu"
  exit 1
fi

# Count VMs
VM_COUNT=$(echo "$QEMU_SCOPES" | wc -l)
echo "🔍 Found ${VM_COUNT} active QEMU VM(s):"
echo "$QEMU_SCOPES" | sed 's/^/   - /'
echo ""

# --- Apply limits strategy based on VM count ---
if [ "$VM_COUNT" -eq 1 ]; then
  echo "📌 Strategy: Single VM detected - applying direct limit (full ${CPU_PCT}%)"
  echo ""
  
  SINGLE_VM=$(echo "$QEMU_SCOPES" | head -n1)
  echo "⚙️  Applying limits to: $SINGLE_VM"
  
  if sudo systemctl set-property "$SINGLE_VM" \
    CPUQuota=${SYSTEMD_CPU_QUOTA}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
    
    echo "   ✅ Success! VM can use full ${CPU_PCT}% of host resources"
  else
    echo "   ❌ Failed to apply limits"
    exit 1
  fi
  
  echo ""
  echo "🔍 Verifying limits:"
  systemctl show "$SINGLE_VM" | grep -E "CPUQuota|MemoryMax|MemorySwapMax"
  
else
  echo "📌 Strategy: Multiple VMs detected - using parent slice for dynamic sharing"
  echo "   → All VMs will share ${CPU_PCT}% CPU and ${RAM_PCT}% RAM dynamically"
  echo "   → Idle VMs release resources to busy VMs automatically"
  echo ""
  
  # Apply limits to machine.slice (parent of all QEMU VMs)
  echo "⚙️  Applying limits to machine.slice (parent cgroup)..."
  
  if sudo systemctl set-property machine.slice \
    CPUQuota=${SYSTEMD_CPU_QUOTA}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M 2>/dev/null; then
    
    echo "   ✅ Success! All ${VM_COUNT} VMs will share resources dynamically"
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
echo "✅ Done! Limits applied successfully."
echo ""
echo "💡 How it works:"
if [ "$VM_COUNT" -eq 1 ]; then
  echo "   • Single VM gets full ${CPU_PCT}% of host resources"
else
  echo "   • Total limit: ${CPU_PCT}% CPU (${SYSTEMD_CPU_QUOTA}%) & ${RAM_PCT}% RAM (${MEM_LIMIT_MB} MB)"
  echo "   • All ${VM_COUNT} VMs share this pool dynamically"
  echo "   • Busy VMs can use more if other VMs are idle"
  echo "   • Total usage never exceeds ${CPU_PCT}% of host"
fi
echo ""
echo "🔄 To reapply after starting/stopping VMs, just run this script again."