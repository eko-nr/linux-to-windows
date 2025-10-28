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
  virsh dumpxml "$VM" > "$TMPDIR/$VM.xml"
  cp "$TMPDIR/$VM.xml" "$TMPDIR/$VM.xml.bak"

  if grep -q "<graphics type='vnc'" "$TMPDIR/$VM.xml"; then
    echo "  → Disabling VNC..."
    if command -v xmlstarlet >/dev/null 2>&1; then
      xmlstarlet ed -P -L -d "//graphics[@type='vnc']" "$TMPDIR/$VM.xml"
    else
      sed -i '/<graphics[^>]*type=.vnc./,/<\/graphics>/d' "$TMPDIR/$VM.xml"
    fi

    if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
      virsh define "$TMPDIR/$VM.xml" >/dev/null
      echo "  ✓ VNC disabled for $VM"

      # Reboot VM (if running)
      if virsh domstate "$VM" | grep -qi running; then
        echo "  ↻ Rebooting $VM..."
        virsh reboot "$VM" >/dev/null || {
          echo "  ⚠ Reboot failed, forcing restart..."
          virsh destroy "$VM" && virsh start "$VM"
        }
      fi
    else
      echo "  ⚠ Invalid XML for $VM — restore backup"
      cp "$TMPDIR/$VM.xml.bak" "$TMPDIR/$VM.xml"
    fi
  else
    echo "  → No VNC found, skipping."
  fi
done

echo
echo "✅ All VMs processed and rebooted where applicable."
echo "Backups stored in: $TMPDIR"
