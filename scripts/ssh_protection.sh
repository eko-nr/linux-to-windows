#!/bin/bash
# ============================================================
# Purpose: Safer setup for Fail2Ban + pam_tally2 on Debian/Ubuntu
# Behavior:
#  - Fail2Ban blocks IPs after 5 failed attempts (bantime 3600s)
#  - pam_tally2 locks account after 5 failed attempts (unlock_time 3600s)
#  - DOES NOT use even_deny_root and DOES NOT restart sshd automatically
#  - Adds current SSH client's IP to Fail2Ban ignoreip
# ============================================================

set -euo pipefail

echo "[0/6] Running as: $(id -un) on $(hostname)"

# get current SSH client IP if available (SSH_CLIENT format: "<ip> <port> <clientport>")
CURRENT_SSH_IP=""
if [ -n "${SSH_CLIENT-}" ]; then
  CURRENT_SSH_IP=$(echo $SSH_CLIENT | awk '{print $1}')
fi

echo "[1/6] Updating package lists and installing dependencies..."
apt update -y
DEBIAN_FRONTEND=noninteractive apt install -y fail2ban libpam-modules || true

echo "[2/6] Backing up existing Fail2Ban config (if any)..."
if [ -f /etc/fail2ban/jail.local ]; then
  cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak_$(date +%F_%T)
fi

echo "[3/6] Configuring Fail2Ban (jail.local)..."
# Build ignoreip line: keep localhost and add current ssh ip if exists
IGNORELINE="ignoreip = 127.0.0.1/8 ::1"
if [ -n "$CURRENT_SSH_IP" ]; then
  IGNORELINE="$IGNORELINE $CURRENT_SSH_IP"
  echo " - Will add current SSH client IP to ignore list: $CURRENT_SSH_IP"
else
  echo " - No SSH_CLIENT IP detected; skip adding ignoreip."
fi

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
$IGNORELINE

[sshd]
enabled = true
port    = ssh
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 600
bantime = 3600
EOF

echo "[4/6] Restarting Fail2Ban only (safe)..."
systemctl enable --now fail2ban
systemctl restart fail2ban

echo "[5/6] Backing up PAM config..."
cp /etc/pam.d/common-auth /etc/pam.d/common-auth.bak_$(date +%F_%T) || true

echo "[6/6] Appending pam_tally2 configuration (NO even_deny_root)..."
# Remove any old pam_tally2 lines (safe cleanup)
if grep -q "pam_tally2.so" /etc/pam.d/common-auth 2>/dev/null; then
  sed -i '/pam_tally2.so/d' /etc/pam.d/common-auth || true
fi

# Append safer pam_tally2 configuration (applies to accounts but skips even_deny_root)
cat >>/etc/pam.d/common-auth <<'EOF'

# ---- pam_tally2: prevent brute-force (lock account after repeated failures) ----
# deny=5           -> lock after 5 failed attempts
# unlock_time=3600 -> automatically unlock after 3600 seconds (1 hour)
# NOTE: not using even_deny_root to avoid immediately locking active root sessions
auth required pam_tally2.so onerr=fail deny=5 unlock_time=3600 root_unlock_time=3600
account required pam_tally2.so
# -------------------------------------------------------------------------------
EOF

echo
echo "✅ Safe setup complete."
echo
echo "IMPORTANT:"
echo " - This script did NOT restart sshd to avoid disconnecting active sessions."
echo " - Fail2Ban was restarted and will protect SSH, ignoring the current SSH client IP (if detected)."
echo
echo "To fully apply PAM changes for new SSH sessions you SHOULD restart sshd, but"
echo "DO THIS ONLY FROM A DIFFERENT SESSION/CLIENT (keep this terminal open):"
echo
echo "    sudo systemctl restart sshd"
echo
echo "Testing checklist (do from ANOTHER client/IP):"
echo " 1) Attempt wrong password 5x from test client — observe ban / lock behavior."
echo " 2) On server (this open session):"
echo "      sudo pam_tally2 --user root"
echo "      sudo fail2ban-client status sshd"
echo
echo "If you are accidentally locked out, from this server/console run:"
echo "  sudo pam_tally2 --user root --reset"
echo "  sudo fail2ban-client set sshd unbanip <YOUR_IP>"
echo
echo "-----------------------------------------------"