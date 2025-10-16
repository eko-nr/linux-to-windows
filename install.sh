#!/bin/bash

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== RDP Port Forwarding Setup for KVM VM ===${NC}\n"

# Configuration
read -p "VM name (default: win10ltsc): " VM_NAME
VM_NAME=${VM_NAME:-win10ltsc}

read -p "Host RDP port (port on VPS, default: 3389): " HOST_RDP_PORT
HOST_RDP_PORT=${HOST_RDP_PORT:-3389}

read -p "Guest RDP port (port in VM, default: 3389): " GUEST_RDP_PORT
GUEST_RDP_PORT=${GUEST_RDP_PORT:-3389}

echo -e "\n${BLUE}Getting VM IP address...${NC}"

# Get VM IP address
VM_IP=$(sudo virsh domifaddr ${VM_NAME} | grep -oP '(\d+\.){3}\d+' | head -1)

if [ -z "$VM_IP" ]; then
    echo -e "${YELLOW}⚠ Cannot detect VM IP automatically.${NC}"
    echo -e "${YELLOW}Make sure Windows is fully installed and network is configured.${NC}"
    read -p "Enter VM IP address manually (e.g., 192.168.122.100): " VM_IP
    
    if [ -z "$VM_IP" ]; then
        echo -e "${RED}✗ No IP address provided. Exiting.${NC}"
        exit 1
    fi
fi

echo -e "${GREEN}✓ VM IP detected: $VM_IP${NC}"

# Display configuration
echo -e "\n${GREEN}=== Configuration Summary ===${NC}"
echo "VM Name        : ${VM_NAME}"
echo "VM IP          : ${VM_IP}"
echo "Host RDP Port  : ${HOST_RDP_PORT}"
echo "Guest RDP Port : ${GUEST_RDP_PORT}"
echo ""
read -p "Continue? (y/n): " CONFIRM

if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    echo -e "${RED}Setup cancelled.${NC}"
    exit 1
fi

echo -e "\n${YELLOW}[1/4] Installing iptables-persistent...${NC}"
sudo apt update
sudo apt install -y iptables-persistent

echo -e "${YELLOW}[2/4] Enabling IP forwarding...${NC}"
# Enable IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1

# Make it persistent
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward=1" | sudo tee -a /etc/sysctl.conf
fi

echo -e "${YELLOW}[3/4] Setting up iptables rules...${NC}"

# Get main network interface
MAIN_IF=$(ip route | grep default | awk '{print $5}' | head -1)
echo "Main interface: $MAIN_IF"

# Remove existing rules if any
sudo iptables -t nat -D PREROUTING -p tcp --dport ${HOST_RDP_PORT} -j DNAT --to-destination ${VM_IP}:${GUEST_RDP_PORT} 2>/dev/null
sudo iptables -D FORWARD -p tcp -d ${VM_IP} --dport ${GUEST_RDP_PORT} -j ACCEPT 2>/dev/null
sudo iptables -t nat -D POSTROUTING -o virbr0 -p tcp -d ${VM_IP} --dport ${GUEST_RDP_PORT} -j MASQUERADE 2>/dev/null

# Add new rules
echo "Adding PREROUTING rule..."
sudo iptables -t nat -A PREROUTING -p tcp --dport ${HOST_RDP_PORT} -j DNAT --to-destination ${VM_IP}:${GUEST_RDP_PORT}

echo "Adding FORWARD rule..."
sudo iptables -A FORWARD -p tcp -d ${VM_IP} --dport ${GUEST_RDP_PORT} -j ACCEPT

echo "Adding POSTROUTING rule..."
sudo iptables -t nat -A POSTROUTING -o virbr0 -p tcp -d ${VM_IP} --dport ${GUEST_RDP_PORT} -j MASQUERADE

echo -e "${YELLOW}[4/4] Saving iptables rules...${NC}"
sudo netfilter-persistent save

echo -e "\n${GREEN}=== Setup Complete! ===${NC}\n"

# Display connection info
VPS_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}✅ RDP Port Forwarding Configured Successfully!${NC}\n"
echo "Connection Information:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "VPS IP Address : ${VPS_IP}"
echo "RDP Port       : ${HOST_RDP_PORT}"
echo "VM IP Address  : ${VM_IP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Windows RDP Client Connection:"
echo "  ${VPS_IP}:${HOST_RDP_PORT}"
echo ""
echo -e "${YELLOW}IMPORTANT: Make sure to enable RDP in Windows first!${NC}"
echo ""
echo "To enable RDP in Windows 10 LTSC:"
echo "  1. Complete Windows installation via VNC"
echo "  2. Open System Properties (Win + Pause)"
echo "  3. Click 'Remote settings'"
echo "  4. Enable 'Allow remote connections to this computer'"
echo "  5. Add user to Remote Desktop Users group"
echo ""
echo "Test RDP connection:"
echo "  From Windows: mstsc /v:${VPS_IP}:${HOST_RDP_PORT}"
echo "  From Linux:   rdesktop ${VPS_IP}:${HOST_RDP_PORT}"
echo ""
echo "Firewall Commands (if needed):"
echo "  Open port: sudo ufw allow ${HOST_RDP_PORT}/tcp"
echo "  Check UFW: sudo ufw status"
echo ""
echo "Verify Rules:"
echo "  sudo iptables -t nat -L PREROUTING -n -v | grep ${HOST_RDP_PORT}"
echo "  sudo iptables -L FORWARD -n -v | grep ${VM_IP}"
echo ""
echo "Remove Port Forwarding:"
echo "  sudo iptables -t nat -D PREROUTING -p tcp --dport ${HOST_RDP_PORT} -j DNAT --to-destination ${VM_IP}:${GUEST_RDP_PORT}"
echo "  sudo iptables -D FORWARD -p tcp -d ${VM_IP} --dport ${GUEST_RDP_PORT} -j ACCEPT"
echo "  sudo netfilter-persistent save"