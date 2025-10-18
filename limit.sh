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
echo "Applying ${CPU_PCT}% CPU, ${RAM_PCT}% RAM, and ${SWAP_PCT}% Swap limits to VM: ${VM}"
echo "-------------------------------------------------------------"

# --- Calculate memory limits ---
TOTAL_MEM=$(grep MemTotal /proc/meminfo | awk '{print $2}') # in kB
MEM_LIMIT_MB=$(awk -v mem="$TOTAL_MEM" -v pct="$RAM_PCT" 'BEGIN { printf "%.0f", mem * (pct/100) / 1024 }')

# --- Calculate swap limit ---
TOTAL_SWAP=$(grep SwapTotal /proc/meminfo | awk '{print $2}')
if [ -z "$TOTAL_SWAP" ] || [ "$TOTAL_SWAP" -eq 0 ]; then
  echo "⚠️  No swap detected on host, setting swap limit to 0."
  SWAP_LIMIT_MB=0
else
  SWAP_LIMIT_MB=$(awk -v swp="$TOTAL_SWAP" -v pct="$SWAP_PCT" 'BEGIN { printf "%.0f", swp * (pct/100) / 1024 }')
fi

# --- Get VM info ---
VCPUS=$(virsh dominfo "$VM" 2>/dev/null | awk '/CPU\(s\)/{print $2}')
if [ -z "$VCPUS" ]; then
  echo "❌ Error: VM '$VM' not found. Check with 'virsh list --all'."
  exit 1
fi

# --- Compute CPU quota ---
QUOTA=$(awk -v vcpu="$VCPUS" -v pct="$CPU_PCT" 'BEGIN { printf "%.0f", vcpu * (pct/100) * 100000 }')

# --- Get VM's max memory (guest side) ---
MAX_MEM_KB=$(sudo virsh dumpxml "$VM" | awk -F'[<>]' '/<memory unit=/ {print $3; exit}')
MAX_MEM_MB=$((MAX_MEM_KB / 1024))

if (( MEM_LIMIT_MB > MAX_MEM_MB )); then
  echo "⚠️ Requested ${MEM_LIMIT_MB} MB exceeds VM max memory (${MAX_MEM_MB} MB)."
  MEM_LIMIT_MB=$MAX_MEM_MB
  echo "➡️ Using ${MEM_LIMIT_MB} MB instead."
fi

# --- Try to find systemd scope for this VM ---
SCOPE_NAME=$(systemctl list-units --type=scope | grep -i "qemu.*${VM}" | awk '{print $1}' | head -n1)

if [ -n "$SCOPE_NAME" ]; then
  echo "🔍 Found systemd unit: $SCOPE_NAME"
  echo "➡️ Applying CPUQuota=${CPU_PCT}%, MemoryMax=${MEM_LIMIT_MB}M, SwapMax=${SWAP_LIMIT_MB}M ..."
  sudo systemctl set-property "$SCOPE_NAME" \
    CPUQuota=${CPU_PCT}% \
    MemoryMax=${MEM_LIMIT_MB}M \
    MemorySwapMax=${SWAP_LIMIT_MB}M

  echo ""
  echo "✅ Done! Systemd limits applied successfully."
  systemctl show "$SCOPE_NAME" | grep -E "CPUQuota|MemoryMax|MemorySwapMax"
else
  echo "⚠️ No systemd scope found for this VM. Falling back to virsh limits..."
  echo "Setting memory limit to ${MEM_LIMIT_MB} MB..."
  sudo virsh setmem "$VM" "${MEM_LIMIT_MB}M" --config

  echo "Setting CPU quota to ${QUOTA} µs per 100000 µs period..."
  sudo virsh schedinfo "$VM" --set vcpu_quota=$QUOTA --set vcpu_period=100000

  echo ""
  echo "✅ Done! virsh-based limits applied."
  sudo virsh schedinfo "$VM" | grep -E "period|quota"
fi