#!/bin/bash
# Remove SIESTE discovery network bridge
# Run as root: sudo ./teardown-network.sh

set -e

BRIDGE="virbr-sieste"
SUBNET="10.99.0.0/24"

echo "=== SIESTE Discovery Network Teardown ==="

# Remove iptables rules
iptables -t nat -D POSTROUTING -s "$SUBNET" ! -d "$SUBNET" -j MASQUERADE 2>/dev/null || true
iptables -D FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT 2>/dev/null || true

# Remove bridge
if ip link show "$BRIDGE" &>/dev/null; then
    echo "Removing bridge $BRIDGE..."
    ip link set "$BRIDGE" down
    ip link delete "$BRIDGE" type bridge
    echo "Bridge removed"
else
    echo "Bridge $BRIDGE does not exist"
fi
