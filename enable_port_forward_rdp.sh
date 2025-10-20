#!/bin/bash
set -e

echo "=== [ Enable Port Forwarding for RDP - Debian ] ==="
echo

# 1️⃣ Detect public interface automatically
PUB_IF=$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)
if [ -z "$PUB_IF" ]; then
    echo "❌ Could not detect public network interface!"
    echo "Please check using: ip a"
    exit 1
fi

PUB_IP=$(ip -4 addr show dev "$PUB_IF" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
echo "Detected public interface: $PUB_IF ($PUB_IP)"
echo

# 2️⃣ Detect active VMs and their IPs via virsh
echo "Scanning for active VMs and their IPs..."
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
echo "Detected VM IP addresses:"
i=1
for VM in "${!VM_IPS[@]}"; do
    echo " [$i] $VM → ${VM_IPS[$VM]}"
    VM_NAMES[$i]="$VM"
    ((i++))
done

read -p "Select VM number to forward RDP to: " CHOICE
VM_NAME=${VM_NAMES[$CHOICE]}
VM_IP=${VM_IPS[$VM_NAME]}

if [ -z "$VM_IP" ]; then
    echo "❌ Invalid selection."
    exit 1
fi

RDP_PORT=3389
echo
echo "Forwarding RDP (TCP+UDP) from $PUB_IP:$RDP_PORT → $VM_NAME ($VM_IP:$RDP_PORT)"
echo

# 3️⃣ Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 4️⃣ Ensure nftables is installed
if ! command -v nft >/dev/null 2>&1; then
    echo "Installing nftables..."
    apt-get update -qq && apt-get install -y nftables >/dev/null
fi

# 5️⃣ Write nftables configuration
echo "Writing nftables configuration to /etc/nftables.conf ..."
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
        iif "$PUB_IF" tcp dport $RDP_PORT dnat to $VM_IP:$RDP_PORT
        iif "$PUB_IF" udp dport $RDP_PORT dnat to $VM_IP:$RDP_PORT
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        oif "$PUB_IF" masquerade
    }
}
EOF

# 6️⃣ Enable and reload nftables
echo "Enabling nftables service..."
systemctl enable nftables >/dev/null 2>&1 || true
systemctl restart nftables

echo
echo "✅ Port forwarding is now active!"
echo "Public RDP: $PUB_IP:$RDP_PORT → VM: $VM_NAME ($VM_IP:$RDP_PORT)"
echo
echo "⚠️ NOTE: Make sure RDP is enabled and running inside the Windows VM,"
echo "         and that the Windows firewall allows incoming RDP (TCP + UDP) connections."
echo
