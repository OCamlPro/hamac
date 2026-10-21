#!/bin/bash
# Stop dnsmasq for Hamac discovery prototype

PID_FILE="/tmp/hamac-dnsmasq.pid"

echo "=== Hamac discovery - Stopping dnsmasq ==="

if [ -f "$PID_FILE" ]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "Stopping dnsmasq (PID $PID)..."
        kill "$PID"
        rm -f "$PID_FILE"
        echo "Stopped"
    else
        echo "Process $PID not running"
        rm -f "$PID_FILE"
    fi
else
    echo "PID file not found, trying pkill..."
    pkill -f "dnsmasq.*hamac" || echo "No dnsmasq process found"
fi
