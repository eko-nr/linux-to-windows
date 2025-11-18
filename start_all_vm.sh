#!/bin/bash
set -e

echo "🔍 Detecting VM for HugePages setup..."

# Get the first defined VM (your system only uses one main VM)
VM_TARGET=$(sudo virsh list --all --name | head -n 1)

if [[ -z "$VM_TARGET" ]]; then
  echo "❌ No VMs found. Exiting."
  exit 0
fi

echo "→ Selected VM: $VM_TARGET"

# HugePage size: 2MB = 2048 KiB
HUGEPAGE_SIZE_KB=2048

# Extract the memory size from VM XML
MEM_KIB=$(sudo virsh dumpxml "$VM_TARGET" \
  | awk -F'[<>]' '/<memory unit='"'"'KiB'"'"'>/ {print $3; exit}')

if [[ -z "$MEM_KIB" ]]; then
  echo "⚠️ Unable to read <memory> from VM XML. HugePages will not be changed."
else
  PAGES=$(( MEM_KIB / HUGEPAGE_SIZE_KB ))
  echo "🧮 VM Memory: ${MEM_KIB} KiB → ${PAGES} HugePages (2MB each)"

  echo "$PAGES" | sudo tee /proc/sys/vm/nr_hugepages > /dev/null
  echo "✅ HugePages applied: $PAGES"
fi

echo ""
echo "🚀 Starting all defined VMs..."

for vm in $(sudo virsh list --all --name); do
  [[ -z "$vm" ]] && continue
  echo "→ Starting $vm"
  if sudo virsh start "$vm"; then
    echo "   ✅ $vm started"
  else
    echo "   ❌ Failed to start $vm"
  fi
done

echo ""
echo "🎉 All VMs started successfully."
