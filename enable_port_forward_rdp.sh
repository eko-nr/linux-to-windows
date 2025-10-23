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

# 2️⃣ Detect active VMs and their IPs via virsh with smart retry
echo "🔍 Scanning for active VMs and their IPs..."
echo "   (Will retry every 2 seconds for up to 60 minutes)"

MAX_ATTEMPTS=1800  # 60 minutes × 30 attempts per minute
ATTEMPT=0
declare -A VM_IPS

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    
    # Get list of running VMs
    VM_LIST=$(virsh list --name 2>/dev/null || true)
    
    if [ -z "$VM_LIST" ]; then
        if [ $ATTEMPT -eq 1 ]; then
            echo "⏳ No running VMs detected yet, waiting..."
        fi
        
        # Progress indicator every 30 attempts (1 minute)
        if [ $((ATTEMPT % 30)) -eq 0 ]; then
            MINUTES=$((ATTEMPT / 30))
            echo "   ... still waiting (${MINUTES} minute(s) elapsed)"
        fi
        
        sleep 2
        continue
    fi
    
    # Try to get IPs for all VMs
    VM_IPS=()
    while read -r VM; do
        if [ -n "$VM" ]; then
            IP=$(virsh domifaddr "$VM" 2>/dev/null | awk '/ipv4/ {print $4}' | cut -d'/' -f1 | head -n1)
            if [ -n "$IP" ]; then
                VM_IPS["$VM"]="$IP"
            fi
        fi
    done <<< "$VM_LIST"
    
    # If we found at least one VM with IP, break
    if [ ${#VM_IPS[@]} -gt 0 ]; then
        echo "✓ VM IP(s) detected after $((ATTEMPT * 2)) seconds"
        break
    fi
    
    # Show waiting message on first attempt
    if [ $ATTEMPT -eq 1 ]; then
        echo "⏳ VMs found but no IPs assigned yet, waiting for network initialization..."
    fi
    
    # Progress indicator every 30 attempts (1 minute)
    if [ $((ATTEMPT % 30)) -eq 0 ]; then
        MINUTES=$((ATTEMPT / 30))
        echo "   ... still waiting for VM IPs (${MINUTES} minute(s) elapsed)"
    fi
    
    sleep 2
done

# Check if we timed out
if [ ${#VM_IPS[@]} -eq 0 ]; then
    echo ""
    echo "❌ Timeout: No VM IPs detected after 60 minutes."
    echo ""
    echo "💡 Possible causes:"
    echo "   • VMs are not running"
    echo "   • VMs haven't finished booting"
    echo "   • QEMU Guest Agent not installed in VMs"
    echo "   • Network interface not configured in VMs"
    echo ""
    echo "🔧 Troubleshooting:"
    echo "   sudo virsh list --all              # Check VM status"
    echo "   sudo virsh domifaddr <vm-name>     # Check specific VM IP"
    echo "   sudo virsh net-list --all          # Check network status"
    echo ""
    echo "You can run this script manually later when VMs are ready."
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
cat > /etc/nftables.conf <<'EOF'
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

cat >> /etc/nftables.conf <<'EOF'
    }

    chain postrouting {
        type nat hook postrouting priority 100;
        oif "$PUB_IF" masquerade
    }
}
EOF

# 6️⃣ Enable and reload nftables with proper error handling
echo "🔄 Enabling nftables service..."
systemctl enable nftables >/dev/null 2>&1 || true

# Test configuration before applying
echo "🔍 Validating nftables configuration..."
if ! nft -c -f /etc/nftables.conf 2>/dev/null; then
    echo "❌ nftables configuration has errors!"
    echo "Showing last 10 lines of config:"
    tail -10 /etc/nftables.conf
    exit 1
fi

# Apply configuration
echo "✅ Configuration valid, applying rules..."
if systemctl restart nftables 2>/dev/null; then
    echo "✅ nftables restarted via systemctl"
elif nft -f /etc/nftables.conf 2>/dev/null; then
    echo "✅ nftables rules loaded manually (systemctl unavailable)"
else
    echo "❌ Failed to load nftables rules!"
    echo ""
    echo "Debug info:"
    echo "─────────────────────────────────────"
    nft -f /etc/nftables.conf 2>&1 || true
    echo "─────────────────────────────────────"
    echo ""
    echo "Configuration file:"
    cat /etc/nftables.conf
    exit 1
fi

# Verify rules are active
echo "🔍 Verifying active rules..."
if nft list ruleset | grep -q "dnat to"; then
    echo "✅ NAT rules confirmed active"
else
    echo "⚠️  Warning: NAT rules not found in active ruleset"
fi

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

# Exit with success
exit 0