#!/bin/bash
# Setup isolated network bridge for SIESTE discovery prototype
# Run as root: sudo ./setup-network.sh

set -e

BRIDGE="virbr-sieste"
SUBNET="10.99.0.0/24"
GATEWAY="10.99.0.1"

echo "=== SIESTE Discovery Network Setup ==="

# Check if bridge already exists
if ip link show "$BRIDGE" &>/dev/null; then
    echo "Bridge $BRIDGE already exists"
    ip addr show "$BRIDGE"
    exit 0
fi

echo "Creating bridge $BRIDGE..."
ip link add name "$BRIDGE" type bridge
ip addr add "$GATEWAY/24" dev "$BRIDGE"
ip link set "$BRIDGE" up

# Enable IP forwarding for the bridge
echo 1 > /proc/sys/net/ipv4/ip_forward

# Add iptables rules for NAT (so VMs can access internet if needed)
iptables -t nat -A POSTROUTING -s "$SUBNET" ! -d "$SUBNET" -j MASQUERADE
iptables -A FORWARD -i "$BRIDGE" -o "$BRIDGE" -j ACCEPT

echo "Bridge $BRIDGE created with gateway $GATEWAY"
echo ""
echo "To remove: sudo ./teardown-network.sh"
