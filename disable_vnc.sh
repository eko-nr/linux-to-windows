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
      sed -i "/<graphics type='vnc'/d" "$TMPDIR/$VM.xml"
    fi
    virsh define "$TMPDIR/$VM.xml" >/dev/null
    echo "  ✓ VNC disabled for $VM"
  else
    echo "  → No VNC found, skipping."
  fi
done

echo
echo "✅ All VMs processed. Backup XMLs are in $TMPDIR"
