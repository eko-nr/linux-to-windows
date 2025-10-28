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

  # Remove any existing graphics (any type)
  if command -v xmlstarlet >/dev/null 2>&1; then
    xmlstarlet ed -P -L -d "//graphics" "$TMPDIR/$VM.xml"
  else
    sed -i '/<graphics /,/<\/graphics>/d' "$TMPDIR/$VM.xml"
  fi

  # Assign sequential ports starting from PORT_BASE
  PORT=$((PORT_BASE + INDEX))
  INDEX=$((INDEX + 1))

  # Insert new graphics tag before </devices>
  sed -i "/<\/devices>/i \  <graphics type='vnc' port='${PORT}' listen='127.0.0.1' autoport='no'/>" "$TMPDIR/$VM.xml"

  # Validate and apply
  if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
    virsh define "$TMPDIR/$VM.xml" >/dev/null
    echo "  ✓ VNC enabled on 127.0.0.1:$PORT for $VM"

    # Power cycle the VM to apply new config
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
echo "✅ All VMs updated and power-cycled where applicable."
echo "Backups stored in: $TMPDIR"
