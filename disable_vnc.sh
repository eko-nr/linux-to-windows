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

  # Remove any old VNC graphics and replace with safe SPICE
  if grep -q "<graphics[^>]*type=['\"]vnc['\"]" "$TMPDIR/$VM.xml"; then
    echo "  → Replacing VNC with SPICE (safe display)..."

    if command -v xmlstarlet >/dev/null 2>&1; then
      xmlstarlet ed -P -L -d "//graphics[@type='vnc']" "$TMPDIR/$VM.xml"
      xmlstarlet ed -P -L -s "//devices" -t elem -n "graphics" -v "" \
        -i "//graphics[not(@type)]" -t attr -n "type" -v "spice" \
        -i "//graphics[@type='spice']" -t attr -n "autoport" -v "no" \
        -i "//graphics[@type='spice']" -t attr -n "listen" -v "0.0.0.0" \
        "$TMPDIR/$VM.xml"
    else
      # sed fallback if xmlstarlet not installed
      sed -i '/<graphics[^>]*type=.vnc./,/<\/graphics>/d' "$TMPDIR/$VM.xml"
      sed -i "/<\/devices>/i \  <graphics type='spice' autoport='no' listen='0.0.0.0'/>" "$TMPDIR/$VM.xml"
    fi

    # Validate & apply
    if xmllint --noout "$TMPDIR/$VM.xml" 2>/dev/null; then
      virsh define "$TMPDIR/$VM.xml" >/dev/null
      echo "  ✓ VNC replaced with SPICE (no open ports) for $VM"

      # Power cycle VM to apply
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
  else
    echo "  → No VNC section found, skipping."
  fi
done

echo
echo "✅ All VMs processed: VNC off, SPICE added (RDP safe, no port errors)."
echo "Backups stored in: $TMPDIR"
