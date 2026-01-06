#!/bin/bash
# End-to-end test for SIESTE infrastructure discovery
#
# This script:
# 1. Starts the discovery server
# 2. Simulates multiple node registrations
# 3. Compiles and runs SIESTE code that queries discovered nodes
# 4. Validates the results

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "============================================"
echo "SIESTE Infrastructure Discovery E2E Test"
echo "============================================"
echo ""
echo "Project root: $PROJECT_ROOT"
echo ""

# Kill any existing discovery server
pkill -f "discovery_server.exe" 2>/dev/null || true
sleep 1

# Start discovery server in background
echo "Step 1: Starting discovery server..."
cd "$PROJECT_ROOT"
opam exec -- dune exec tools/discovery-prototype/discovery-server/discovery_server.exe &
SERVER_PID=$!
echo "Server started (PID: $SERVER_PID)"
sleep 2

# Check server is running
if ! curl -s http://localhost:8877/health | grep -q '"ok"'; then
    echo "ERROR: Discovery server failed to start"
    kill $SERVER_PID 2>/dev/null || true
    exit 1
fi
echo "Server health check: OK"
echo ""

# Register test nodes
echo "Step 2: Registering test nodes..."
chmod +x "$SCRIPT_DIR/test-qemu-simple.sh"

# Register different types of nodes
"$SCRIPT_DIR/test-qemu-simple.sh" compute-node-1 >/dev/null
"$SCRIPT_DIR/test-qemu-simple.sh" compute-node-2 >/dev/null
"$SCRIPT_DIR/test-qemu-simple.sh" storage-node-1 >/dev/null
"$SCRIPT_DIR/test-qemu-simple.sh" gateway-node-1 >/dev/null

# Also register with explicit roles
curl -s -X POST http://localhost:8877/register \
    -H "Content-Type: application/json" \
    -d '{"hostname":"db-master","ip_address":"10.99.0.50","mac_address":"52:54:00:db:00:01","cpus":8,"memory_mb":32768,"disk_gb":500,"metadata":{"role":"database","rack":"rack-1"}}' >/dev/null

curl -s -X POST http://localhost:8877/register \
    -H "Content-Type: application/json" \
    -d '{"hostname":"db-replica","ip_address":"10.99.0.51","mac_address":"52:54:00:db:00:02","cpus":8,"memory_mb":32768,"disk_gb":500,"metadata":{"role":"database","rack":"rack-2"}}' >/dev/null

echo "Registered 6 test nodes"
echo ""

# List all nodes
echo "Step 3: Verifying registered nodes..."
NODES=$(curl -s http://localhost:8877/nodes)
NODE_COUNT=$(echo "$NODES" | grep -o '"count":[0-9]*' | cut -d: -f2)
echo "Discovery server reports $NODE_COUNT nodes"
echo ""

# Create test SIESTE file
echo "Step 4: Creating SIESTE test file..."
TEST_FILE="/tmp/sieste_e2e_test.zzz"
cat > "$TEST_FILE" << 'SIESTE_EOF'
# E2E Test: Infrastructure Discovery
# This file tests the discovery system end-to-end

use stdlib::option{type option, Some, None}
use stdlib::list{type list}
use stdlib::discovery{type DiscoveredNode, fetch_discovered_nodes, filter_by_role, get_metadata}
use stdlib::network{type Node, type SecurityZone}

# Fetch all nodes from discovery server
def all_discovered := fetch_discovered_nodes("http://localhost:8877")

# Filter database nodes
def db_nodes := filter_by_role(all_discovered, "database")

# Count function for verification
def count_nodes(nodes: list[DiscoveredNode]) -> int:
    match nodes:
        | list::Nil -> 0
        | list::Cons(_, rest) -> 1 + count_nodes(rest)

def total_count := count_nodes(all_discovered)
def db_count := count_nodes(db_nodes)

# Results
def test_results := total_count
SIESTE_EOF

echo "Test file created: $TEST_FILE"
echo ""

# Compile and run SIESTE code
echo "Step 5: Compiling and evaluating SIESTE code..."
cd "$PROJECT_ROOT"
SIESTE_STDLIB=./stdlib opam exec -- _build/default/pkgs/sieste/main.exe compile --eval=true "$TEST_FILE" 2>&1 | tee /tmp/sieste_e2e_output.txt

# Check results
echo ""
echo "Step 6: Verifying results..."
if grep -q "Evaluation complete" /tmp/sieste_e2e_output.txt; then
    echo "SIESTE evaluation: SUCCESS"
else
    echo "SIESTE evaluation: FAILED"
    cat /tmp/sieste_e2e_output.txt
fi

# Check for compilation success
if grep -q "Compilation successful" /tmp/sieste_e2e_output.txt; then
    echo "SIESTE compilation: SUCCESS"
else
    echo "SIESTE compilation: FAILED"
fi

# Final summary
echo ""
echo "============================================"
echo "E2E Test Summary"
echo "============================================"
echo "Discovery Server: Running (PID $SERVER_PID)"
echo "Nodes Registered: $NODE_COUNT"
echo "SIESTE Compilation: $(grep -q 'Compilation successful' /tmp/sieste_e2e_output.txt && echo 'PASS' || echo 'FAIL')"
echo "SIESTE Evaluation: $(grep -q 'Evaluation complete' /tmp/sieste_e2e_output.txt && echo 'PASS' || echo 'FAIL')"
echo ""

# Cleanup
echo "Stopping discovery server..."
kill $SERVER_PID 2>/dev/null || true

echo ""
echo "E2E Test Complete!"
