#!/bin/bash
# Start dnsmasq for SIESTE discovery prototype
# Run as root: sudo ./start-dnsmasq.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/dnsmasq.conf"
TFTP_DIR="$SCRIPT_DIR/tftp"
PID_FILE="/tmp/sieste-dnsmasq.pid"

echo "=== SIESTE Discovery - Starting dnsmasq ==="

# Check if already running
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "dnsmasq already running (PID $(cat "$PID_FILE"))"
    exit 0
fi

# Create TFTP directory if needed
mkdir -p "$TFTP_DIR"

# Check for pxelinux files
if [ ! -f "$TFTP_DIR/pxelinux.0" ]; then
    echo "WARNING: pxelinux.0 not found in $TFTP_DIR"
    echo "Run: ./setup-pxe-files.sh to download required files"
fi

# Update config with absolute path
sed -i "s|tftp-root=.*|tftp-root=$TFTP_DIR|" "$CONF"

# Start dnsmasq
echo "Starting dnsmasq with config: $CONF"
dnsmasq -C "$CONF" -d &
DNSMASQ_PID=$!
echo $DNSMASQ_PID > "$PID_FILE"

echo "dnsmasq started (PID $DNSMASQ_PID)"
echo ""
echo "To stop: sudo kill $DNSMASQ_PID"
echo "Or: sudo ./stop-dnsmasq.sh"

# Wait for dnsmasq
wait $DNSMASQ_PID
