#!/bin/bash
set -e

TABLE_NAME="inet filter"
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
  # Make sure nftables service is running
  if ! systemctl is-active --quiet nftables; then
    echo "Starting nftables service..."
    systemctl start nftables
  fi

  # Create table if missing (safe)
  if ! nft list tables | grep -q "$TABLE_NAME"; then
    echo "Creating table '$TABLE_NAME'..."
    nft add table $TABLE_NAME
  fi

  # Ensure INPUT chain exists
  if ! nft list chain $TABLE_NAME input >/dev/null 2>&1; then
    echo "Creating INPUT chain..."
    nft add chain $TABLE_NAME input { type filter hook input priority 0\; policy accept\; }
  fi

  # Ensure FORWARD chain exists
  if ! nft list chain $TABLE_NAME forward >/dev/null 2>&1; then
    echo "Creating FORWARD chain..."
    nft add chain $TABLE_NAME forward { type filter hook forward priority 0\; policy accept\; }
  fi
}

block_vnc() {
  echo "🔒 Blocking VNC ports (5900–5999)..."
  ensure_nftables_ready

  for CHAIN in input forward; do
    if nft list chain $TABLE_NAME $CHAIN | grep -q "$RULE_COMMENT"; then
      echo "✅ Rule already exists in chain '$CHAIN', skipping."
    else
      echo "➕ Adding rule to chain '$CHAIN'..."
      nft add rule $TABLE_NAME $CHAIN tcp dport 5900-5999 counter drop comment \"$RULE_COMMENT\"
      echo "✅ Added rule to '$CHAIN' chain."
    fi
  done
}

enable_vnc() {
  echo "🔓 Enabling VNC (removing block rules)..."
  for CHAIN in input forward; do
    # Check and remove rule safely
    if nft list chain $TABLE_NAME $CHAIN | grep -q "$RULE_COMMENT"; then
      HANDLE=$(nft list chain $TABLE_NAME $CHAIN | grep -B1 "$RULE_COMMENT" | head -1 | awk '{print $2}')
      if [ -n "$HANDLE" ]; then
        nft delete rule $TABLE_NAME $CHAIN handle "$HANDLE"
        echo "✅ Removed rule from '$CHAIN' chain."
      else
        echo "⚠️  Could not determine handle for '$CHAIN' chain, skipping."
      fi
    else
      echo "ℹ️  No VNC block rule found in '$CHAIN' chain."
    fi
  done
}

show_rules() {
  echo "📜 Current nftables rules (inet filter):"
  nft list table $TABLE_NAME | sed 's/^/   /'
}

# === Menu Loop ===
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
