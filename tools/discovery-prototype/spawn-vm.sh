#!/bin/bash
# Spawn a test VM with PXE boot for SIESTE discovery prototype
# Usage: ./spawn-vm.sh <vm-name> [memory-mb] [cpus]

set -e

VM_NAME="${1:-test-node}"
MEMORY="${2:-512}"
CPUS="${3:-1}"
BRIDGE="virbr-sieste"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_DIR="$SCRIPT_DIR/vms"
DISK="$VM_DIR/$VM_NAME.qcow2"

echo "=== SIESTE Discovery - Spawning VM: $VM_NAME ==="

# Check if bridge exists
if ! ip link show "$BRIDGE" &>/dev/null; then
    echo "ERROR: Bridge $BRIDGE not found"
    echo "Run: sudo ./setup-network.sh"
    exit 1
fi

# Create VM directory
mkdir -p "$VM_DIR"

# Create disk image if not exists
if [ ! -f "$DISK" ]; then
    echo "Creating disk image: $DISK (1GB)"
    qemu-img create -f qcow2 "$DISK" 1G
fi

echo "Starting VM with:"
echo "  Name: $VM_NAME"
echo "  Memory: ${MEMORY}MB"
echo "  CPUs: $CPUS"
echo "  Bridge: $BRIDGE"
echo "  Disk: $DISK"
echo ""

# Generate unique MAC address based on VM name
MAC_SUFFIX=$(echo -n "$VM_NAME" | md5sum | cut -c1-6)
MAC="52:54:00:${MAC_SUFFIX:0:2}:${MAC_SUFFIX:2:2}:${MAC_SUFFIX:4:2}"
echo "  MAC: $MAC"

# Start QEMU VM with PXE boot
# -boot n = network boot first
# -netdev bridge connects to our bridge
qemu-system-x86_64 \
    -name "$VM_NAME" \
    -m "$MEMORY" \
    -smp "$CPUS" \
    -enable-kvm \
    -boot n \
    -drive file="$DISK",format=qcow2,if=virtio \
    -netdev bridge,id=net0,br="$BRIDGE" \
    -device virtio-net-pci,netdev=net0,mac="$MAC" \
    -nographic \
    -serial mon:stdio \
    &

VM_PID=$!
echo ""
echo "VM started (PID $VM_PID)"
echo "Press Ctrl+A, X to exit QEMU"
echo ""

wait $VM_PID
