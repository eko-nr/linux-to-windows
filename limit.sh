#!/bin/bash
# --- Dependencies ---
sudo apt-get install -y bc >/dev/null 2>&1

# --- Prompt user for inputs ---
read -p "Enter VM name [default: win10ltsc]: " VM
VM=${VM:-win10ltsc}

read -p "Enter maximum CPU usage percentage [default: 88]: " CPU_PCT
CPU_PCT=${CPU_PCT:-88}

read -p "Enter maximum RAM usage percentage [default: 88]: " RAM_PCT
RAM_PCT=${RAM_PCT:-88}

read -p "Enter maximum SWAP usage percentage [default: 100]: " SWAP_PCT
SWAP_PCT=${SWAP_PCT:-100}

echo ""
echo "Applying ${CPU_PCT}% CPU (${HOST_CPUS} cores) and ${RAM_PCT}% RAM (${TOTAL_MEM_MB} MB) limits to VM: ${VM}"
echo "-------------------------------------------------------------"

# --- Detect host resources ---
HOST_CPUS=$(nproc)
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in kB
TOTAL_MEM_MB=$((TOTAL_MEM / 1024))

echo "ℹ️  Host has ${HOST_CPUS} CPU cores and ${TOTAL_MEM_MB} MB RAM"

# --- Calculate memory limits based on HOST total RAM ---
MEM_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$RAM_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')

# --- Calculate swap limit based on HOST total RAM ---
TOTAL_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ -z "$TOTAL_SWAP" ] || [ "$TOTAL_SWAP" -eq 0 ]; then
  echo "⚠️  No swap detected on host, setting swap limit to 0."
  SWAP_LIMIT_MB=0
else
  # Swap limit based on host total RAM (not swap size)
  SWAP_LIMIT_MB=$(awk -v mem="$TOTAL_MEM_MB" -v pct="$SWAP_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) }')
fi

# --- Get VM info ---
VCPUS=$(virsh dominfo "$VM" 2>/dev/null | awk '/CPU\(s\)/{print $2}')
if [ -z "$VCPUS" ]; then
  echo "❌ Error: VM '$VM' not found. Check with 'virsh list --all'."
  exit 1
fi

# --- Detect host CPU count ---
HOST_CPUS=$(nproc)
echo "ℹ️  Host has ${HOST_CPUS} CPU cores"

# --- Compute CPU quota based on HOST cores ---
# For virsh: quota in microseconds per period
QUOTA=$(awk -v host="$HOST_CPUS" -v pct="$CPU_PCT" 'BEGIN { printf "%.0f", host * (pct/100) * 100000 }')

# For systemd: CPUQuota must be multiplied by host CPU count
SYSTEMD_CPU_QUOTA=$(awk -v host="$HOST_CPUS" -v pct="$CPU_PCT" 'BEGIN { printf "%.0f", host * pct }')

# --- Check VM's allocated memory ---
VM_ALLOCATED_MEM_KB=$(sudo virsh dumpxml "$VM" | awk -F'[<>]' '/<memory unit=/ {print $3; exit}')
VM_ALLOCATED_MEM_MB=$((VM_ALLOCATED_MEM_KB / 1024))

# Warn if limit exceeds VM allocation
if (( MEM_LIMIT_MB > VM_ALLOCATED_MEM_MB )); then
  echo "⚠️  Warning: Calculated limit ${MEM_LIMIT_MB} MB exceeds VM allocated memory (${VM_ALLOCATED_MEM_MB} MB)"
  echo "⚠️  VM can only use up to its allocated memory. Consider increasing VM allocation or lowering percentage."
fi

# --- Try to find systemd scope for this VM ---
SCOPE_NAME=$(systemctl list-units --type=scope | grep -i "qemu.*${VM}" | awk '{print $1}' | head -n1)

if [ -n "$SCOPE_NAME" ]; then
  echo "🔍 Found systemd unit: $SCOPE_NAME"
  echo "ℹ️  VM has ${VCPUS} vCPUs (host has ${HOST_CPUS} cores)"
  echo "➡️ Applying CPUQuota=${SYSTEMD_CPU_QUOTA}% (${CPU_PCT}% × ${HOST_CPUS} host cores)"
  echo "➡️ Applying MemoryMax=${MEM_LIMIT_MB}M, SwapMax=${SWAP_LIMIT_MB}M ..."
  
  sudo systemctl set-property "$SCOPE_NAME" \
    CPUQuota=${SYSTEMD_CPU_QUOTA}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M
  
  echo ""
  echo "✅ Done! Systemd limits applied successfully."
  echo ""
  systemctl show "$SCOPE_NAME" | grep -E "CPUQuota|MemoryMax|MemorySwapMax"
else
  echo "⚠️ No systemd scope found for this VM. Falling back to virsh limits..."
  echo "ℹ️  VM has ${VCPUS} vCPUs (host has ${HOST_CPUS} cores)"
  echo "Setting memory limit to ${MEM_LIMIT_MB} MB..."
  sudo virsh setmem "$VM" "${MEM_LIMIT_MB}M" --config
  
  echo "Setting CPU quota to ${QUOTA} µs per 100000 µs period (${CPU_PCT}% × ${HOST_CPUS} host cores)..."
  sudo virsh schedinfo "$VM" --set vcpu_quota=$QUOTA --set vcpu_period=100000
  
  echo ""
  echo "✅ Done! virsh-based limits applied."
  sudo virsh schedinfo "$VM" | grep -E "period|quota"
fi