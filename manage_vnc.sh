#!/bin/bash
set -e

TABLE_NAME="inet filter"
RULE_COMMENT="block-vnc-external"

# Detect public interface automatically
EXT_IF=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {print $5; exit}')
[ -z "$EXT_IF" ] && { echo "❌ Could not detect external interface."; exit 1; }

show_menu() {
  echo "=============================="
  echo "  Manage External VNC Access  "
  echo "=============================="
  echo "Detected external interface: $EXT_IF"
  echo "1) Block external VNC (5900–5999)"
  echo "2) Enable (unblock) external VNC"
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
  if ! nft list tables | grep -q "$TABLE_NAME"; then
    echo "Creating table '$TABLE_NAME'..."
    nft add table $TABLE_NAME
  fi

  # Ensure INPUT and FORWARD chains exist
  for CHAIN in input forward; do
    if ! nft list chain $TABLE_NAME $CHAIN >/dev/null 2>&1; then
      echo "Creating chain '$CHAIN'..."
      nft add chain $TABLE_NAME $CHAIN { type filter hook $CHAIN priority 0\; policy accept\; }
    fi
  done
}

block_vnc() {
  echo "🔒 Blocking external VNC access on interface '$EXT_IF'..."
  ensure_nftables_ready

  for CHAIN in input forward; do
    if nft list chain $TABLE_NAME $CHAIN | grep -q "$RULE_COMMENT"; then
      echo "✅ Rule already exists in chain '$CHAIN', skipping."
    else
      nft add rule $TABLE_NAME $CHAIN iifname "$EXT_IF" tcp dport 5900-5999 counter drop comment \"$RULE_COMMENT\"
      echo "✅ Added rule to '$CHAIN' for interface '$EXT_IF'."
    fi
  done
}

enable_vnc() {
  echo "🔓 Enabling external VNC (removing block rules)..."
  for CHAIN in input forward; do
    if nft list chain $TABLE_NAME $CHAIN | grep -q "$RULE_COMMENT"; then
      # Extract handle numbers robustly
      HANDLES=$(nft --handle list chain $TABLE_NAME $CHAIN | \
                awk '/handle/ && /block-vnc-external/ {for(i=1;i<=NF;i++) if($i=="handle") print $(i+1)}')
      if [ -n "$HANDLES" ]; then
        for HANDLE in $HANDLES; do
          if [[ "$HANDLE" =~ ^[0-9]+$ ]]; then
            echo "🗑  Removing rule handle $HANDLE from chain '$CHAIN'..."
            nft delete rule $TABLE_NAME $CHAIN handle "$HANDLE"
          fi
        done
        echo "✅ Removed all '$RULE_COMMENT' rules from '$CHAIN'."
      else
        echo "⚠️  No valid handles found in '$CHAIN', skipping."
      fi
    else
      echo "ℹ️  No VNC block rule found in '$CHAIN'."
    fi
  done
}

show_rules() {
  echo "📜 Current nftables rules (inet filter):"
  nft list table $TABLE_NAME | sed 's/^/   /'
}

# === Menu loop ===
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
