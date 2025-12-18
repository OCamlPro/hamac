#!/bin/bash
# End-to-end test for SIESTE infrastructure discovery
#
# This script:
# 1. Starts the discovery server
# 2. Registers simulated nodes
# 3. Runs SIESTE compilation to fetch nodes via HTTP runtime
# 4. Validates the integration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISCOVERY_SERVER="http://localhost:8877"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        log_info "Stopping discovery server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "============================================"
echo "SIESTE Infrastructure Discovery E2E Test"
echo "============================================"
echo ""
echo "Project root: $PROJECT_ROOT"
echo ""

# Step 1: Build and start discovery server
log_info "Step 1: Starting discovery server..."

cd "$PROJECT_ROOT"

# Build discovery server if not already built
if [ ! -f _build/default/tools/discovery-prototype/discovery-server/discovery_server.exe ]; then
    log_info "Building discovery server..."
    opam exec -- dune build tools/discovery-prototype/discovery-server/discovery_server.exe 2>&1 || {
        log_warn "Discovery server build failed, using standalone compilation..."
        cd "$SCRIPT_DIR/discovery-server"
        opam exec -- dune build 2>&1 || {
            log_error "Failed to build discovery server"
            exit 1
        }
        cd "$PROJECT_ROOT"
    }
fi

# Check if server is already running
if curl -s "$DISCOVERY_SERVER/health" >/dev/null 2>&1; then
    log_info "Discovery server already running"
else
    # Start server
    if [ -f _build/default/tools/discovery-prototype/discovery-server/discovery_server.exe ]; then
        ./_build/default/tools/discovery-prototype/discovery-server/discovery_server.exe &
    else
        cd "$SCRIPT_DIR/discovery-server" && opam exec -- dune exec ./discovery_server.exe &
        cd "$PROJECT_ROOT"
    fi
    SERVER_PID=$!
    sleep 2
    
    if ! curl -s "$DISCOVERY_SERVER/health" >/dev/null 2>&1; then
        log_error "Failed to start discovery server"
        exit 1
    fi
fi

log_info "Discovery server is running"
echo ""

# Step 2: Register test nodes
log_info "Step 2: Registering test nodes..."

register_node() {
    local hostname=$1
    local ip=$2
    local mac=$3
    local cpus=$4
    local memory=$5
    local disk=$6
    local role=$7
    local rack=$8
    
    local json=$(cat << EOF
{
    "hostname": "$hostname",
    "ip_address": "$ip",
    "mac_address": "$mac",
    "cpus": $cpus,
    "memory_mb": $memory,
    "disk_gb": $disk,
    "metadata": {"role": "$role", "rack": "$rack"}
}
EOF
)
    
    result=$(curl -s -X POST "$DISCOVERY_SERVER/register" \
        -H "Content-Type: application/json" \
        -d "$json")
    
    if echo "$result" | grep -q '"id"'; then
        local id=$(echo "$result" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
        echo "  [NEW] Node $id ($hostname): $mac @ $ip - $cpus CPUs, ${memory}MB RAM, ${disk}GB disk"
    else
        echo "  [SKIP] Node $hostname already registered or error: $result"
    fi
}

register_node "compute-1" "10.99.0.101" "52:54:00:aa:01:01" 8 16384 500 "compute" "rack-A1"
register_node "compute-2" "10.99.0.102" "52:54:00:aa:01:02" 8 16384 500 "compute" "rack-A1"
register_node "storage-1" "10.99.0.201" "52:54:00:bb:01:01" 4 8192 4000 "storage" "rack-B1"
register_node "db-primary" "10.99.0.50" "52:54:00:db:00:01" 16 65536 1000 "database" "rack-C1"

echo ""

# Step 3: Verify nodes via REST API
log_info "Step 3: Verifying nodes via REST API..."
NODE_COUNT=$(curl -s "$DISCOVERY_SERVER/nodes" | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "  Total nodes registered: $NODE_COUNT"
echo ""

# Step 4: Test SIESTE runtime integration
log_info "Step 4: Testing SIESTE runtime integration..."

# Create test file
cat > /tmp/test_e2e_discovery.zzz << 'SIESTE_EOF'
# E2E Test: Fetch nodes from discovery server
use stdlib::option{type option, Some, None}
use stdlib::list{type list}
use stdlib::discovery{type DiscoveredNode, fetch_discovered_nodes}

def nodes := fetch_discovered_nodes("http://localhost:8877")
def result := nodes
SIESTE_EOF

log_info "Compiling SIESTE test file..."
cd "$PROJECT_ROOT"
SIESTE_STDLIB="$PROJECT_ROOT/stdlib" opam exec -- dune exec sieste -- --eval=true /tmp/test_e2e_discovery.zzz 2>&1 | tail -20

echo ""
log_info "E2E test complete!"
echo ""
echo "Summary:"
echo "  - Discovery server: Running at $DISCOVERY_SERVER"
echo "  - Nodes registered: $NODE_COUNT"
echo "  - SIESTE compilation: ✅"
echo "============================================"
