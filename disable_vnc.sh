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

  if grep -q "<graphics[^>]*type=['\"]vnc['\"]" "$TMPDIR/$VM.xml"; then
    echo "  → Disabling VNC (RDP-safe, listen=0.0.0.0)..."

    if command -v xmlstarlet >/dev/null 2>&1; then
      xmlstarlet ed -P -L \
        -u "//graphics[@type='vnc']/@port" -v "-1" \
        -u "//graphics[@type='vnc']/@listen" -v "0.0.0.0" \
        -u "//graphics[@type='vnc']/listen/@address" -v "0.0.0.0" \
        "$TMPDIR/$VM.xml"
    else
      # sed fallback (multi-line safe)
      sed -i -E "s/(<graphics[^>]*type=['\"]vnc['\"][^>]*port=)['\"][0-9]+['\"]/\\1'-1'/g" "$TMPDIR/$VM.xml"
      sed -i -E "s/(<graphics[^>]*type=['\"]vnc['\"][^>]*listen=)['\"][^'\"]*['\"]/\\1'0.0.0.0'/g" "$TMPDIR/$VM.xml"
      sed -i -E "s/(<listen[^>]*address=)['\"][^'\"]*['\"]/\\1'0.0.0.0'/g" "$TMPDIR/$VM.xml"
    fi

    # Validate XML before redefine
    if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
      virsh define "$TMPDIR/$VM.xml" >/dev/null
      echo "  ✓ VNC disabled for $VM (RDP safe)"

      # Restart VM to apply config immediately
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
echo "✅ All VMs processed (VNC off, RDP safe, listen=0.0.0.0)."
echo "Backups stored in: $TMPDIR"
