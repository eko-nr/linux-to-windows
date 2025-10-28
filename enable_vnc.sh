#!/bin/bash

set -e

echo "==============================="
echo "   Enable VNC for all VMs"
echo "==============================="

# Ask for starting port
read -rp "Enter starting VNC port (default 5901): " PORT_BASE
PORT_BASE=${PORT_BASE:-5901}

TMPDIR=$(mktemp -d /tmp/enable-vnc-XXXX)
echo "Working directory: $TMPDIR"

# Get all VM names
VMS=$(virsh list --all --name | grep -v '^$')

if [ -z "$VMS" ]; then
  echo "No VMs found!"
  exit 0
fi

INDEX=0

for VM in $VMS; do
  echo "Processing VM: $VM"
  virsh dumpxml "$VM" > "$TMPDIR/$VM.xml"

  cp "$TMPDIR/$VM.xml" "$TMPDIR/$VM.xml.bak"

  # Remove existing <graphics> tags (any type)
  if command -v xmlstarlet >/dev/null 2>&1; then
    xmlstarlet ed -P -L -d "//graphics" "$TMPDIR/$VM.xml"
  else
    sed -i "/<graphics /d" "$TMPDIR/$VM.xml"
  fi

  # Assign a new port for each VM
  PORT=$((PORT_BASE + INDEX))
  INDEX=$((INDEX + 1))

  # Insert a new graphics tag
  sed -i "/<\/devices>/i \  <graphics type='vnc' port='${PORT}' listen='127.0.0.1' autoport='no'/>" "$TMPDIR/$VM.xml"

  virsh define "$TMPDIR/$VM.xml" >/dev/null
  echo "  ✓ VNC enabled on 127.0.0.1:$PORT for $VM"
done

echo
echo "✅ All VMs updated successfully."
echo "Backups of original XMLs are in: $TMPDIR"
