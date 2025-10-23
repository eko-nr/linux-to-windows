#!/bin/bash
set -e

echo "=== [ Auto Enable Port Forwarding for All Active VMs - RDP ] ==="
echo

# 1️⃣ Detect public interface automatically
PUB_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
if [ -z "$PUB_IF" ]; then
    echo "❌ Could not detect public network interface!"
    echo "Please check using: ip a"
    exit 1
fi

PUB_IP=$(ip -4 addr show dev "$PUB_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
echo "✓ Detected public interface: $PUB_IF ($PUB_IP)"
echo

# 2️⃣ Detect active VMs and their IPs via virsh
echo "🔍 Scanning for active VMs and their IPs..."
VM_LIST=$(virsh list --name)
if [ -z "$VM_LIST" ]; then
    echo "❌ No running VMs detected. Start your Windows VM first!"
    exit 1
fi

declare -A VM_IPS
while read -r VM; do
    if [ -n "$VM" ]; then
        IP=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -n1)
        if [ -n "$IP" ]; then
            VM_IPS["$VM"]="$IP"
        fi
    fi
done <<< "$VM_LIST"

if [ ${#VM_IPS[@]} -eq 0 ]; then
    echo "❌ No VM IPs detected. Ensure the VMs have network connectivity and Guest Agent is installed."
    exit 1
fi

echo
echo "✓ Detected VMs:"
RDP_BASE_PORT=3389
PORT_COUNTER=0
declare -A PORT_MAPPING

for VM in "${!VM_IPS[@]}"; do
    ASSIGNED_PORT=$((RDP_BASE_PORT + PORT_COUNTER))
    PORT_MAPPING["$VM"]="$ASSIGNED_PORT"
    echo "  • $VM → ${VM_IPS[$VM]} (Port: $ASSIGNED_PORT)"
    ((PORT_COUNTER++))
done

echo

# 3️⃣ Enable IP forwarding
echo "⚙️  Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 4️⃣ Ensure nftables is installed
if ! command -v nft >/dev/null 2>&1; then
    echo "📦 Installing nftables..."
    apt-get update -qq && apt-get install -y nftables >/dev/null
fi

# 5️⃣ Write nftables configuration with all VMs
echo "📝 Writing nftables configuration to /etc/nftables.conf ..."
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0;
        policy accept;
    }

    chain forward {
        type filter hook forward priority 0;
        policy accept;
    }

    chain output {
        type filter hook output priority 0;
        policy accept;
    }
}

table ip nat {
    chain prerouting {
        type nat hook prerouting priority 0;
EOF

# Add rules for each VM
for VM in "${!VM_IPS[@]}"; do
    VM_IP="${VM_IPS[$VM]}"
    ASSIGNED_PORT="${PORT_MAPPING[$VM]}"
    
    cat >> /etc/nftables.conf <<EOF
        # RDP forwarding for $VM
        iif "$PUB_IF" tcp dport $ASSIGNED_PORT dnat to $VM_IP:3389
        iif "$PUB_IF" udp dport $ASSIGNED_PORT dnat to $VM_IP:3389
EOF
done

cat >> /etc/nftables.conf <<EOF
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        oif "$PUB_IF" masquerade
    }
}
EOF

# 6️⃣ Enable and reload nftables
echo "🔄 Enabling nftables service..."
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

echo
echo "✅ Port forwarding is now active for all VMs!"
echo
echo "📋 RDP Connection Details:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for VM in "${!VM_IPS[@]}"; do
    VM_IP="${VM_IPS[$VM]}"
    ASSIGNED_PORT="${PORT_MAPPING[$VM]}"
    echo "  VM: $VM"
    echo "  └─ Connect to: $PUB_IP:$ASSIGNED_PORT"
    echo "  └─ Forwards to: $VM_IP:3389"
    echo
done
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo
echo "⚠️  NOTE:"
echo "  • Ensure RDP is enabled inside each Windows VM"
echo "  • Windows firewall must allow RDP (TCP + UDP port 3389)"
echo "  • Multiple VMs use different ports (3389, 3390, 3391, etc.)"
echo