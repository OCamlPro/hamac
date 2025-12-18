#!/bin/bash
# Test QEMU boot with direct kernel loading
#
# This test boots a VM directly with our initramfs to verify:
# 1. The initramfs boots correctly
# 2. The init script runs
# 3. Network can be configured
#
# Uses QEMU user-mode networking (no root required, no bridge setup)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TFTP_DIR="$SCRIPT_DIR/tftp"

# Check prerequisites
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    echo "Install with: sudo apt install qemu-system-x86"
    exit 1
fi

if [ ! -f "$TFTP_DIR/vmlinuz" ] || [ ! -f "$TFTP_DIR/initrd.img" ]; then
    echo "ERROR: Missing kernel or initrd"
    echo "Run: $SCRIPT_DIR/build-pxe-image.sh && $SCRIPT_DIR/download-kernel.sh"
    exit 1
fi

# Discovery server URL - uses host network via QEMU user-mode
DISCOVERY_URL="${DISCOVERY_URL:-http://10.0.2.2:8877}"

echo "============================================"
echo "SIESTE QEMU Direct Boot Test"
echo "============================================"
echo ""
echo "Kernel: $TFTP_DIR/vmlinuz"
echo "Initrd: $TFTP_DIR/initrd.img"
echo "Discovery Server: $DISCOVERY_URL"
echo ""
echo "NOTE: The VM will use QEMU user-mode networking."
echo "      Host's localhost:8877 is accessible at 10.0.2.2:8877 from VM."
echo ""
echo "Starting QEMU..."
echo "Press Ctrl+A, X to exit QEMU."
echo ""

# Run QEMU with user-mode networking
# - Uses serial console for output
# - Host port 8877 is accessible at 10.0.2.2:8877 inside VM
qemu-system-x86_64 \
    -kernel "$TFTP_DIR/vmlinuz" \
    -initrd "$TFTP_DIR/initrd.img" \
    -append "console=ttyS0 sieste.discovery=$DISCOVERY_URL" \
    -m 256M \
    -nographic \
    -no-reboot \
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \
    -device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56
