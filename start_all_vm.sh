#!/bin/bash
set -e

echo "🔍 Detecting VM for HugePages setup..."

VM_TARGET=$(sudo virsh list --all --name | grep -v '^$' | head -n 1)

if [[ -z "$VM_TARGET" ]]; then
  echo "❌ No VMs found. Exiting."
  exit 0
fi

echo "→ Selected VM: $VM_TARGET"

HUGEPAGE_SIZE_KB=2048

MEM_KIB=$(sudo virsh dumpxml "$VM_TARGET" \
  | awk -F'[<>]' '/<memory unit='"'"'KiB'"'"'>/ {print $3; exit}')

if [[ -z "$MEM_KIB" ]]; then
  echo "⚠️ Cannot read memory from XML. Skipping HugePages."
  PAGES=0
else
  PAGES=$(( MEM_KIB / HUGEPAGE_SIZE_KB ))
  echo "🧮 VM Memory: ${MEM_KIB} KiB → ${PAGES} HugePages (2MB/pages)"

  echo "$PAGES" | sudo tee /proc/sys/vm/nr_hugepages > /dev/null
  echo "✅ HugePages applied: $PAGES pages"
fi

echo ""
echo "🚀 Starting VM: $VM_TARGET"

if sudo virsh start "$VM_TARGET"; then
  echo "🎉 $VM_TARGET started with HugePages"
else
  echo "❌ Failed to start $VM_TARGET"
fi
