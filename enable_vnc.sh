#!/bin/bash
# Enable VNC for all libvirt VMs (listen only on localhost)
# Author: ChatGPT
# Date: 2025-10-29

set -e

TMPDIR=$(mktemp -d /tmp/enable-vnc-XXXX)
echo "Working in $TMPDIR"

VMS=$(virsh list --all --name | grep -v '^$')

if [ -z "$VMS" ]; then
  echo "No VMs found!"
  exit 0
fi

PORT_BASE=5900
INDEX=0

for VM in $VMS; do
  echo "Processing VM: $VM"
  virsh dumpxml "$VM" > "$TMPDIR/$VM.xml"

  cp "$TMPDIR/$VM.xml" "$TMPDIR/$VM.xml.bak"

  # Remove any existing graphics tags first
  if command -v xmlstarlet >/dev/null 2>&1; then
    xmlstarlet ed -P -L -d "//graphics" "$TMPDIR/$VM.xml"
  else
    sed -i "/<graphics /d" "$TMPDIR/$VM.xml"
  fi

  # Assign unique port per VM (incrementally)
  PORT=$((PORT_BASE + INDEX))
  INDEX=$((INDEX + 1))

  # Insert new graphics tag before </devices>
  sed -i "/<\/devices>/i \  <graphics type='vnc' port='${PORT}' listen='127.0.0.1' autoport='no'/>" "$TMPDIR/$VM.xml"

  virsh define "$TMPDIR/$VM.xml" >/dev/null
  echo "  ✓ VNC enabled on 127.0.0.1:$PORT for $VM"
done

echo
echo "✅ All VMs now have VNC enabled. Backup XMLs are in $TMPDIR"
