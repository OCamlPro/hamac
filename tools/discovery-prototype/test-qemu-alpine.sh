#!/bin/bash
# Test QEMU boot with Alpine Linux initramfs (has network drivers)
#
# Uses Alpine's official netboot kernel and initramfs which includes
# all necessary drivers for virtio networking.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TFTP_DIR="$SCRIPT_DIR/tftp"

# Check prerequisites
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    exit 1
fi

if [ ! -f "$TFTP_DIR/vmlinuz" ] || [ ! -f "$TFTP_DIR/initramfs-lts" ]; then
    echo "ERROR: Missing kernel or initramfs"
    echo "Download with:"
    echo "  curl -L -o $TFTP_DIR/vmlinuz https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/netboot/vmlinuz-lts"
    echo "  curl -L -o $TFTP_DIR/initramfs-lts https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/x86_64/netboot/initramfs-lts"
    exit 1
fi

echo "============================================"
echo "SIESTE QEMU Alpine Boot Test"
echo "============================================"
echo ""
echo "Kernel: $TFTP_DIR/vmlinuz"
echo "Initrd: $TFTP_DIR/initramfs-lts"
echo ""
echo "This will boot Alpine Linux in rescue mode."
echo "Once booted, you can manually register with the discovery server:"
echo ""
echo "  # Get network info"
echo "  ip addr"
echo "  "
echo "  # Register with discovery server (from inside VM)"
echo "  wget -q -O - --post-data='{\"hostname\":\"alpine-vm\",\"ip_address\":\"10.0.2.15\",\"mac_address\":\"52:54:00:12:34:56\",\"cpus\":1,\"memory_mb\":256,\"disk_gb\":10,\"metadata\":{\"boot_method\":\"qemu\"}}' --header='Content-Type: application/json' http://10.0.2.2:8877/register"
echo ""
echo "Press Ctrl+A, X to exit QEMU."
echo ""

# Run QEMU with Alpine initramfs
qemu-system-x86_64 \
    -kernel "$TFTP_DIR/vmlinuz" \
    -initrd "$TFTP_DIR/initramfs-lts" \
    -append "console=ttyS0 modules=virtio_net,virtio_pci" \
    -m 512M \
    -nographic \
    -no-reboot \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
