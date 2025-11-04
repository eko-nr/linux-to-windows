#!/bin/bash
set -euo pipefail

# ====== Configurable parameters ======
BANTIME="-1"        # -1 = permanent ban
FINDTIME="6000"      # seconds (10 minutes window)
MAXRETRY="5"        # allowed failures
DESTEMAIL=""        # optional: set email for alerts, or leave blank
SENDER="fail2ban@$(hostname -f || echo localhost)"
# =====================================

echo "== Fail2Ban permanent SSH protection setup =="

# Detect current SSH client IP
CURRENT_SSH_IP=""
if [ -n "${SSH_CLIENT-}" ]; then
  CURRENT_SSH_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
fi

if [ -n "$CURRENT_SSH_IP" ]; then
  echo "Detected current SSH IP: $CURRENT_SSH_IP (will be whitelisted)"
else
  echo "No SSH client IP detected (probably local/console run)."
fi

echo "[1/4] Installing Fail2Ban..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y fail2ban mailutils sendmail || true

echo "[2/4] Backing up old config..."
if [ -f /etc/fail2ban/jail.local ]; then
  cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak_$(date +%F_%T)
  echo "Backup saved as jail.local.bak_*"
fi

echo "[3/4] Writing new /etc/fail2ban/jail.local..."
IGNORELINE="ignoreip = 127.0.0.1/8 ::1"
[ -n "$CURRENT_SSH_IP" ] && IGNORELINE="$IGNORELINE $CURRENT_SSH_IP"

EMAIL_BLOCK=""
if [ -n "$DESTEMAIL" ]; then
  EMAIL_BLOCK=$(cat <<EOF
destemail = $DESTEMAIL
sender = $SENDER
mta = sendmail
action = %(action_mwl)s
EOF
)
fi

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Whitelisted IPs
$IGNORELINE

# Ban configuration
bantime  = $BANTIME        # -1 means permanent ban
findtime = $FINDTIME
maxretry = $MAXRETRY

# Optional mail notifications
$EMAIL_BLOCK

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = $MAXRETRY
findtime = $FINDTIME
bantime  = $BANTIME
EOF

echo "[4/4] Enabling & restarting Fail2Ban..."
systemctl enable --now fail2ban
systemctl restart fail2ban

echo
echo "✅ Setup complete — permanent ban enabled."
echo
echo "Service status:"
systemctl --no-pager --full status fail2ban | grep -E 'Active|Loaded'
echo
echo "Check jail status:"
sudo fail2ban-client status sshd
echo
echo "📘 Useful commands:"
echo " - View logs:            sudo tail -f /var/log/fail2ban.log"
echo " - Check jail:           sudo fail2ban-client status sshd"
echo " - See banned IPs:       sudo fail2ban-client status sshd"
echo " - Unban IP manually:    sudo fail2ban-client set sshd unbanip <IP>"
echo " - Add whitelist IP:     sudo sed -i '/^ignoreip/ s/\$ / <IP>/' /etc/fail2ban/jail.local && sudo systemctl restart fail2ban"
echo
echo "⚠️  WARNING: Once banned, IPs stay blocked FOREVER until manually unbanned."
echo "Make sure your trusted IPs are added to ignoreip above!"
echo
echo "Testing tip:"
echo "  Try wrong password $MAXRETRY times from another IP — that IP will be banned permanently."
echo
echo "== Done =="