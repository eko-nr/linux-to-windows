sudo apt install nftables -y

# 6️⃣ Enable and reload nftables
echo "🔄 Enabling nftables service..."
systemctl enable nftables >/dev/null 2>&1 || true

# Reload with better error handling
if systemctl restart nftables 2>/dev/null; then
    echo "✅ nftables restarted successfully"
else
    echo "⚠️  systemctl restart failed, trying manual reload..."
    if nft -f /etc/nftables.conf 2>/dev/null; then
        echo "✅ nftables rules loaded manually"
    else
        echo "❌ Failed to load nftables rules"
        echo "Check configuration: nft -f /etc/nftables.conf"
        exit 1
    fi
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

# Exit with success code
exit 0