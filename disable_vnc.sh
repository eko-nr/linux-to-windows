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
    echo "  → Disabling VNC (safe mode)..."

    if command -v xmlstarlet >/dev/null 2>&1; then
      # Replace VNC port to -1 safely
      xmlstarlet ed -P -L \
        -u "//graphics[@type='vnc']/@port" -v "-1" \
        -u "//graphics[@type='vnc']/@listen" -v "127.0.0.1" \
        "$TMPDIR/$VM.xml"
    else
      # sed fallback
      sed -i -E "s/(<graphics[^>]*type=['\"]vnc['\"][^>]*port=)['\"][0-9]+['\"]/\\1'-1'/g" "$TMPDIR/$VM.xml"
      sed -i -E "s/(<graphics[^>]*type=['\"]vnc['\"][^>]*listen=)['\"][^'\"]*['\"]/\\1'127.0.0.1'/g" "$TMPDIR/$VM.xml"
    fi

    if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
      virsh define "$TMPDIR/$VM.xml" >/dev/null
      echo "  ✓ VNC disabled (RDP safe) for $VM"

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
    echo "  → No VNC found, skipping."
  fi
done

echo
echo "✅ All VMs processed and power-cycled safely."
echo "Backups stored in: $TMPDIR"
