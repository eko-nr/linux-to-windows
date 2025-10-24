#!/bin/bash
set -e

echo "=== 🔧 Swap and Swappiness Configuration ==="
read -p "Enter new swap size (e.g., 15G): " SWAP_SIZE
read -p "Enter swappiness value (e.g., 70): " SWAPPINESS

echo ""
echo "🧩 Disabling existing swap..."
sudo swapoff -a || true

if [ -f /swapfile ]; then
  echo "🧹 Removing old /swapfile..."
  sudo rm -f /swapfile
fi

echo "📦 Creating new swapfile of size $SWAP_SIZE..."
if ! sudo fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null; then
  echo "⚠️ fallocate failed, using dd instead..."
  sudo dd if=/dev/zero of=/swapfile bs=1M count=$(( ${SWAP_SIZE//[!0-9]/} * 1024 )) status=progress
fi

echo "🔒 Setting permissions..."
sudo chmod 600 /swapfile

echo "🧱 Formatting as swap..."
sudo mkswap /swapfile

echo "🚀 Enabling swap..."
sudo swapon /swapfile

echo "📝 Ensuring /etc/fstab entry..."
if ! grep -q '^/swapfile' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab > /dev/null
fi

echo "⚙️ Setting swappiness to $SWAPPINESS..."
sudo sysctl vm.swappiness=$SWAPPINESS

if grep -q '^vm.swappiness' /etc/sysctl.conf; then
  sudo sed -i "s/^vm\.swappiness=.*/vm.swappiness=$SWAPPINESS/" /etc/sysctl.conf
else
  echo "vm.swappiness=$SWAPPINESS" | sudo tee -a /etc/sysctl.conf > /dev/null
fi

sudo sysctl -p > /dev/null

echo ""
echo "✅ Done!"
echo "Swap size: $SWAP_SIZE"
echo "Swappiness: $SWAPPINESS"
echo ""
swapon --show
free -h