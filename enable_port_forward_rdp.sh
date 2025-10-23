#!/bin/bash

echo "=== [ Auto Enable Port Forwarding for All Active VMs - RDP ] ==="
echo

# 🔹 Detect public network interface automatically
PUB_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
PUB_IP=$(ip -4 addr show dev "$PUB_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
echo "✓ Detected public interface: $PUB_IF ($PUB_IP)"
echo

# 🔹 Detect active VMs and their internal IPs
echo "🔍 Scanning for active VMs..."
VM_LIST=$(virsh list --name 2>/dev/null || true)
TMP_MAP=$(mktemp)
> "$TMP_MAP"

for VM in $VM_LIST; do
  IP=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -n1)
  [ -n "$IP" ] && echo "$VM $IP" >> "$TMP_MAP"
done

if [ ! -s "$TMP_MAP" ]; then
  echo "❌ No VMs with IP detected. (QEMU Guest Agent might be missing)"
  exit 1
fi

echo "✓ Detected VM(s):"
cat "$TMP_MAP"
echo

# 🔹 Enable IPv4 forwarding on the host
echo "⚙️  Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

# 🔹 Write nftables configuration
CONF=/etc/nftables.conf
BASE_PORT=3389
COUNT=0

{
  echo "#!/usr/sbin/nft -f"
  echo "flush ruleset"
  echo
  echo "table inet filter {"
  echo "  chain input { type filter hook input priority 0; policy accept; }"
  echo "  chain forward { type filter hook forward priority 0; policy accept; }"
  echo "  chain output { type filter hook output priority 0; policy accept; }"
  echo "}"
  echo
  echo "table ip nat {"
  echo "  chain prerouting {"
  echo "    type nat hook prerouting priority 0;"
  while read -r VM IP; do
    PORT=$((BASE_PORT + COUNT))
    echo "    # $VM"
    echo "    iif \"$PUB_IF\" tcp dport $PORT dnat to $IP:3389"
    echo "    iif \"$PUB_IF\" udp dport $PORT dnat to $IP:3389"
    ((COUNT++))
  done < "$TMP_MAP"
  echo "  }"
  echo "  chain postrouting {"
  echo "    type nat hook postrouting priority 100;"
  echo "    oif \"$PUB_IF\" masquerade"
  echo "  }"
  echo "}"
} > "$CONF"

# 🔹 Debug output
echo
echo "────────────────────────────"
echo "DEBUG: /etc/nftables.conf content"
cat "$CONF"
echo "────────────────────────────"
echo

# 🔹 Apply rules and enable nftables permanently
echo "🔍 Loading nftables configuration..."
nft -f /etc/nftables.conf
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables || nft -f /etc/nftables.conf

# 🔹 Verify rules are active
echo
echo "🧩 Verifying active rules..."
nft list ruleset | grep dnat || echo "⚠️  No DNAT rules found!"
echo
echo "💾 nftables service status:"
systemctl status nftables --no-pager | grep -E 'Loaded:|Active:'
echo

# 🔹 Show summary of forwarding rules
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RDP CONNECTION DETAILS:"
COUNT=0
while read -r VM IP; do
  PORT=$((3389 + COUNT))
  echo "  VM: $VM"
  echo "  →  Connect via RDP: $PUB_IP:$PORT"
  echo "  →  Forwards to: $IP:3389"
  ((COUNT++))
  echo
done < "$TMP_MAP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "✅ Port forwarding is active and persistent across reboots."
echo "⚠️  Ensure Windows RDP is enabled and firewall allows TCP/UDP 3389."
echo
