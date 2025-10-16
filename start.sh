VM_NAME=${VM_NAME:-win10ltsc}

sudo virsh start $VM_NAME && echo "VM started"

echo "Check Logs Commands:"
echo "  VM Logs:           sudo virsh dumpxml ${VM_NAME}"
echo "  QEMU Logs:         sudo tail -f /var/log/libvirt/qemu/${VM_NAME}.log"
echo "  Libvirt Logs:      sudo tail -f /var/log/libvirt/libvirtd.log"
echo "  System Logs:       sudo journalctl -u libvirtd -f"
echo "  VM Console:        sudo virsh console ${VM_NAME}"
echo "  All VM Logs:       sudo ls -lh /var/log/libvirt/qemu/"