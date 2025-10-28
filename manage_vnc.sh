#!/bin/bash
set -e

TABLE_NAME="inet filter"
CHAIN_NAME="input"
RULE_COMMENT="block-vnc-ports"

show_menu() {
  echo "=============================="
  echo "     Manage VNC Firewall"
  echo "=============================="
  echo "1) Block VNC ports (5900–5999)"
  echo "2) Enable VNC (remove block)"
  echo "3) Show current rules"
  echo "4) Exit"
  echo "=============================="
}

ensure_nftables_ready() {
  if ! systemctl is-active --quiet nftables; then
    echo "Starting nftables service..."
    systemctl start nftables
  fi

  # Create table if missing
  if ! nft list tables | grep -q "inet filter"; then
    echo "Creating table 'inet filter'..."
    nft add table inet filter
  fi

  # Create chain if missing
  if ! nft list chain inet filter input >/dev/null 2>&1; then
    echo "Creating chain 'input'..."
    nft add chain inet filter input { type filter hook input priority 0\; policy accept\; }
  fi
}

block_vnc() {
  echo "🔒 Blocking VNC ports (5900–5999)..."
  ensure_nftables_ready

  if nft list chain inet filter input | grep -q "$RULE_COMMENT"; then
    echo "✅ Rule already exists, skipping duplicate."
  else
    nft add rule inet filter input tcp dport 5900-5999 counter drop comment \"$RULE_COMMENT\"
    echo "✅ Rule added successfully (without touching other rules)."
  fi
}

enable_vnc() {
  echo "🔓 Enabling VNC (removing block rule)..."
  if nft list chain inet filter input | grep -q "$RULE_COMMENT"; then
    RULE_HANDLE=$(nft list chain inet filter input | grep -B1 "$RULE_COMMENT" | head -1 | awk '{print $2}')
    if [ -n "$RULE_HANDLE" ]; then
      nft delete rule inet filter input handle "$RULE_HANDLE"
      echo "✅ VNC block rule removed."
    else
      echo "⚠️  Could not find rule handle — no changes made."
    fi
  else
    echo "ℹ️  No existing VNC block rule found."
  fi
}

show_rules() {
  echo "📜 Current nftables rules (input chain):"
  nft list chain inet filter input | sed 's/^/   /'
}

while true; do
  show_menu
  read -rp "Select an option [1-4]: " choice
  case $choice in
    1) block_vnc ;;
    2) enable_vnc ;;
    3) show_rules ;;
    4) echo "Exiting."; exit 0 ;;
    *) echo "Invalid choice. Please try again." ;;
  esac
  echo
done
