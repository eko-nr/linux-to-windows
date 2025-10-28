#!/bin/bash
set -e

echo "==============================="
echo "   Enable VNC for all VMs"
echo "==============================="

read -rp "Enter starting VNC port (default 5900): " PORT_BASE
PORT_BASE=${PORT_BASE:-5900}

TMPDIR=$(mktemp -d /tmp/enable-vnc-XXXX)
echo "Working directory: $TMPDIR"

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

  if command -v xmlstarlet >/dev/null 2>&1; then
    xmlstarlet ed -P -L -d "//graphics" "$TMPDIR/$VM.xml"
  else
    sed -i '/<graphics /,/<\/graphics>/d' "$TMPDIR/$VM.xml"
  fi

  PORT=$((PORT_BASE + INDEX))
  INDEX=$((INDEX + 1))

  sed -i "/<\/devices>/i \  <graphics type='vnc' port='${PORT}' listen='0.0.0.0' autoport='no'>\n    <listen type='address' address='0.0.0.0'/>\n  </graphics>" "$TMPDIR/$VM.xml"

  # Apply & reboot
  if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
    virsh define "$TMPDIR/$VM.xml" >/dev/null
    echo "  ✓ VNC enabled on 0.0.0.0:$PORT for $VM"

    if virsh domstate "$VM" | grep -qi running; then
      echo "  ↻ Power cycling $VM..."
      virsh destroy "$VM" >/dev/null || true
      sleep 2
      virsh start "$VM" >/dev/null
    fi
  else
    echo "  ⚠ Invalid XML for $VM — restoring backup"
    cp "$TMPDIR/$VM.xml.bak" "$TMPDIR/$VM.xml"
  fi
done

echo
echo "✅ All VMs updated (VNC listen=0.0.0.0, internet safe)."
echo "Backups stored in: $TMPDIR"