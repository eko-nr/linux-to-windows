#!/bin/bash
set -euo pipefail

# ====== Configuration ======
BANTIME="-1"        # -1 = permanent ban
FINDTIME="6000"     # 100 minutes (seconds)
MAXRETRY="5"        # 5 failed attempts before ban
# ============================

echo "== Fail2Ban permanent SSH protection setup (systemd backend) =="

# Detect current SSH client IP (for whitelist)
CURRENT_SSH_IP=""
if [ -n "${SSH_CLIENT-}" ]; then
  CURRENT_SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
fi

if [ -n "$CURRENT_SSH_IP" ]; then
  echo "Detected SSH client IP: $CURRENT_SSH_IP (will be whitelisted)"
else
  echo "No SSH client IP detected (likely console/local run)."
fi

echo "[1/3] Installing Fail2Ban..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y fail2ban || true

echo "[2/3] Backing up any old config..."
if [ -f /etc/fail2ban/jail.local ]; then
  cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak_$(date +%F_%T)
  echo "Backup created: jail.local.bak_*"
fi

echo "[3/3] Writing new configuration..."
IGNORELINE="ignoreip = 127.0.0.1/8 ::1"
[ -n "$CURRENT_SSH_IP" ] && IGNORELINE="$IGNORELINE $CURRENT_SSH_IP"

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Trusted IPs (your current session is whitelisted)
$IGNORELINE

# Ban settings
bantime  = $BANTIME
findtime = $FINDTIME
maxretry = $MAXRETRY

[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = $MAXRETRY
findtime = $FINDTIME
bantime  = $BANTIME
EOF

echo "Restarting Fail2Ban..."
systemctl enable --now fail2ban
systemctl restart fail2ban

echo
echo "✅ Setup complete — Fail2Ban is now active."
echo
echo "Service status:"
systemctl --no-pager --full status fail2ban | grep -E 'Active|Loaded'
echo
echo "Check jail status:"
sudo fail2ban-client status sshd || true
echo
echo "📘 Useful commands:"
echo " - Check logs:       sudo tail -f /var/log/fail2ban.log"
echo " - Check jail:       sudo fail2ban-client status sshd"
echo " - Unban IP:         sudo fail2ban-client set sshd unbanip <IP>"
echo
echo "⚠️  WARNING: Once banned, IPs stay blocked FOREVER (bantime=-1)."
echo "Make sure your trusted IPs are in the ignoreip list."
echo
echo "Testing tip:"
echo "  From another IP, try wrong password $MAXRETRY times within 100 minutes — that IP will be permanently banned."
echo
echo "== Done =="
