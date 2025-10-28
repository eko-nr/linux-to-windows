#!/bin/bash
set -e

echo "==============================="
echo "   Enable VNC for all VMs"
echo "==============================="

# Ask user for base port
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

  # Remove any old graphics entries
  if command -v xmlstarlet >/dev/null 2>&1; then
    xmlstarlet ed -P -L -d "//graphics" "$TMPDIR/$VM.xml"
  else
    sed -i '/<graphics /,/<\/graphics>/d' "$TMPDIR/$VM.xml"
  fi

  # Assign a unique VNC port
  PORT=$((PORT_BASE + INDEX))
  INDEX=$((INDEX + 1))

  # Insert the new VNC graphics config
  sed -i "/<\/devices>/i \  <graphics type='vnc' port='${PORT}' listen='127.0.0.1' autoport='no'/>" "$TMPDIR/$VM.xml"

  virsh define "$TMPDIR/$VM.xml" >/dev/null
  echo "  ✓ VNC enabled on 127.0.0.1:$PORT for $VM"

  # Reboot VM (if running)
  if virsh domstate "$VM" | grep -qi running; then
    echo "  ↻ Rebooting $VM..."
    virsh reboot "$VM" >/dev/null || {
      echo "  ⚠ Reboot failed, forcing restart..."
      virsh destroy "$VM" && virsh start "$VM"
    }
  fi
done

echo
echo "✅ All VMs updated and rebooted where applicable."
echo "Backups stored in: $TMPDIR"
