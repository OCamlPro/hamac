#!/bin/bash
# Start the SIESTE Discovery Server
# Usage: ./start-discovery-server.sh [port]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$SCRIPT_DIR/discovery-server"
PORT="${1:-8877}"

echo "=== SIESTE Discovery Server ==="

cd "$SERVER_DIR"

# Build if needed
if [ ! -f "_build/default/discovery_server.exe" ]; then
    echo "Building discovery server..."
    opam exec -- dune build
fi

# Run
echo "Starting on port $PORT..."
PORT=$PORT opam exec -- dune exec ./discovery_server.exe
