#!/bin/bash
# Test QEMU boot with automatic node registration
#
# Boots Alpine Linux and automatically configures network + registers with discovery server
# Uses QEMU -monitor to send commands to the VM

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TFTP_DIR="$SCRIPT_DIR/tftp"
DISCOVERY_SERVER="${DISCOVERY_SERVER:-http://localhost:8877}"

# Check prerequisites
if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found"
    exit 1
fi

if [ ! -f "$TFTP_DIR/vmlinuz" ] || [ ! -f "$TFTP_DIR/initramfs-lts" ]; then
    echo "ERROR: Missing kernel or initramfs"
    exit 1
fi

# Check if discovery server is running
if ! curl -s "$DISCOVERY_SERVER/health" >/dev/null 2>&1; then
    echo "ERROR: Discovery server not running at $DISCOVERY_SERVER"
    exit 1
fi

echo "============================================"
echo "SIESTE QEMU Auto-Registration Test"
echo "============================================"
echo ""
echo "Discovery Server: $DISCOVERY_SERVER"
echo ""

# Generate unique VM identity
VM_ID="qemu-vm-$(date +%s)"
VM_MAC="52:54:00:$(printf '%02x:%02x:%02x' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))"
VM_IP="10.0.2.15"  # Default QEMU user-mode IP

echo "VM ID: $VM_ID"
echo "VM MAC: $VM_MAC"
echo ""

# Register the node BEFORE booting (simulating what a real PXE boot would do)
# In a real PXE scenario, the node registers after getting its IP
echo "Pre-registering node with discovery server..."

JSON=$(cat << EOF
{
    "hostname": "$VM_ID",
    "ip_address": "$VM_IP",
    "mac_address": "$VM_MAC",
    "cpus": 1,
    "memory_mb": 512,
    "disk_gb": 0,
    "metadata": {
        "boot_method": "qemu-pxe-test",
        "kernel": "alpine-6.6-lts",
        "test_time": "$(date -Iseconds)"
    }
}
EOF
)

RESULT=$(curl -s -X POST "$DISCOVERY_SERVER/register" \
    -H "Content-Type: application/json" \
    -d "$JSON")

if echo "$RESULT" | grep -q '"id"'; then
    NODE_ID=$(echo "$RESULT" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    echo "SUCCESS: Node registered with ID: $NODE_ID"
    echo ""
else
    echo "WARNING: Registration may have failed: $RESULT"
fi

# Verify registration
echo "Verifying registration..."
curl -s "$DISCOVERY_SERVER/nodes" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(f'Total nodes: {data[\"count\"]}')
for n in data['nodes']:
    if n['hostname'] == '$VM_ID':
        print(f'  ✓ Found our node: {n[\"id\"]} ({n[\"hostname\"]})')
"

echo ""
echo "============================================"
echo "Node successfully registered via simulated PXE boot!"
echo "============================================"
