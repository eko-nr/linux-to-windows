#!/bin/bash
set -e

TMPDIR=$(mktemp -d /tmp/disable-vnc-XXXX)
echo "Working in $TMPDIR"

VMS=$(virsh list --all --name | grep -v '^$')

if [ -z "$VMS" ]; then
  echo "No VMs found!"
  exit 0
fi

for VM in $VMS; do
  echo "Processing VM: $VM"

  # Dump XML and backup
  virsh dumpxml "$VM" > "$TMPDIR/$VM.xml"
  cp "$TMPDIR/$VM.xml" "$TMPDIR/$VM.xml.bak"

  # Remove any graphics block of type 'vnc'
  if grep -q "<graphics[^>]*type=['\"]vnc['\"]" "$TMPDIR/$VM.xml"; then
    echo "  → Disabling VNC..."
    if command -v xmlstarlet >/dev/null 2>&1; then
      xmlstarlet ed -P -L -d "//graphics[@type='vnc']" "$TMPDIR/$VM.xml"
    else
      # fallback sed (handles multi-line <graphics>...</graphics>)
      sed -i '/<graphics[^>]*type=.vnc./,/<\/graphics>/d' "$TMPDIR/$VM.xml"
    fi

    # Validate XML
    if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
      virsh define "$TMPDIR/$VM.xml" >/dev/null
      echo "  ✓ VNC disabled for $VM"

      # Force full power cycle so QEMU reloads new XML
      if virsh domstate "$VM" | grep -qi running; then
        echo "  ↻ Power cycling $VM..."
        virsh destroy "$VM" >/dev/null || true
        sleep 2
        virsh start "$VM" >/dev/null
      fi
    else
      echo "  ⚠ Invalid XML for $VM — restoring backup."
      cp "$TMPDIR/$VM.xml.bak" "$TMPDIR/$VM.xml"
    fi
  else
    echo "  → No VNC section found, skipping."
  fi
done

echo
echo "✅ All VMs processed and power-cycled where applicable."
echo "Backups are stored in: $TMPDIR"