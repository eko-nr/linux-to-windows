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

# 2️⃣ Ask for Windows VM IP
read -p "Enter your Windows VM IP (e.g., 192.168.122.194): " VM_IP
if [[ -z "$VM_IP" ]]; then
    echo "❌ Windows VM IP cannot be empty!"
    exit 1
fi

RDP_PORT=3389
echo "Forwarding RDP from $PUB_IP:$RDP_PORT → $VM_IP:$RDP_PORT"
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
cat <<EOF > /etc/nftables.conf
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
echo "Public RDP: $PUB_IP:$RDP_PORT → Windows VM: $VM_IP:$RDP_PORT"
echo "You can now connect via Remote Desktop to: $PUB_IP"
echo