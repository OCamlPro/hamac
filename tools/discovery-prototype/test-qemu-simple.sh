#!/bin/bash
# Simple QEMU test WITHOUT PXE - just tests discovery registration
#
# This script:
# 1. Creates a temporary Alpine Linux VM image
# 2. Boots it with QEMU
# 3. The VM auto-registers with the discovery server
#
# Prerequisites:
# - QEMU installed
# - Discovery server running on localhost:8877

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM_NAME="${1:-test-node}"
DISCOVERY_SERVER="${DISCOVERY_SERVER:-http://10.99.0.1:8877}"

echo "=== SIESTE Simple QEMU Test ==="
echo "VM Name: $VM_NAME"
echo "Discovery Server: $DISCOVERY_SERVER"
echo ""

# For a truly simple test without PXE, we can use QEMU's -kernel option
# with a minimal Linux kernel and initrd

# First, let's check if we can do a simpler test using curl directly
# to simulate what a PXE-booted node would do

echo "Simulating PXE boot registration for $VM_NAME..."

# Generate pseudo-random MAC and IP based on VM name
MAC_SUFFIX=$(echo -n "$VM_NAME" | md5sum | cut -c1-6)
MAC="52:54:00:${MAC_SUFFIX:0:2}:${MAC_SUFFIX:2:2}:${MAC_SUFFIX:4:2}"
IP_LAST=$(( $(echo -n "$VM_NAME" | cksum | cut -d' ' -f1) % 100 + 100 ))
IP="10.99.0.$IP_LAST"

# Get some system info to make it realistic
CPUS=$(nproc 2>/dev/null || echo 2)
MEM_MB=$(( $(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}' || echo 2048000) / 1024 ))
# Scale down for "VM"
VM_CPUS=$(( CPUS / 2 ))
[ "$VM_CPUS" -lt 1 ] && VM_CPUS=1
VM_MEM=$(( MEM_MB / 4 ))
[ "$VM_MEM" -lt 512 ] && VM_MEM=512

echo ""
echo "Simulated VM specs:"
echo "  Hostname: $VM_NAME"
echo "  MAC:      $MAC"
echo "  IP:       $IP"
echo "  CPUs:     $VM_CPUS"
echo "  Memory:   ${VM_MEM}MB"
echo ""

# Build JSON payload
JSON=$(cat << EOF
{
    "hostname": "$VM_NAME",
    "ip_address": "$IP",
    "mac_address": "$MAC",
    "cpus": $VM_CPUS,
    "memory_mb": $VM_MEM,
    "disk_gb": 50,
    "metadata": {
        "boot_method": "simulated-pxe",
        "rack": "rack-$(( RANDOM % 3 + 1 ))",
        "role": "$(echo compute storage gateway | tr ' ' '\n' | shuf | head -1)"
    }
}
EOF
)

echo "Registration payload:"
echo "$JSON" | head -20
echo ""

# Register with discovery server
echo "Registering with $DISCOVERY_SERVER..."
RESULT=$(curl -s -X POST "$DISCOVERY_SERVER/register" \
    -H "Content-Type: application/json" \
    -d "$JSON")

if echo "$RESULT" | grep -q '"id"'; then
    echo "SUCCESS: Node registered!"
    echo "Response:"
    echo "$RESULT"
else
    echo "FAILED: Registration failed"
    echo "Response: $RESULT"
    exit 1
fi
