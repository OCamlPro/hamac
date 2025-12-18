#!/bin/bash
# Test the SIESTE Discovery Server with simulated nodes
# Usage: ./test-discovery.sh [server-url]

SERVER="${1:-http://localhost:8877}"

echo "=== SIESTE Discovery Server Test ==="
echo "Server: $SERVER"
echo ""

# Test health endpoint
echo "1. Health check..."
curl -s "$SERVER/health" | jq .
echo ""

# Register first node
echo "2. Registering node1..."
curl -s -X POST "$SERVER/register" \
    -H "Content-Type: application/json" \
    -d '{
        "hostname": "compute-node-1",
        "ip_address": "10.99.0.101",
        "mac_address": "52:54:00:aa:bb:01",
        "cpus": 8,
        "memory_mb": 16384,
        "disk_gb": 500,
        "metadata": {
            "rack": "A1",
            "role": "compute"
        }
    }' | jq .
echo ""

# Register second node
echo "3. Registering node2..."
curl -s -X POST "$SERVER/register" \
    -H "Content-Type: application/json" \
    -d '{
        "hostname": "storage-node-1",
        "ip_address": "10.99.0.102",
        "mac_address": "52:54:00:aa:bb:02",
        "cpus": 4,
        "memory_mb": 8192,
        "disk_gb": 2000,
        "metadata": {
            "rack": "A2",
            "role": "storage"
        }
    }' | jq .
echo ""

# Register third node
echo "4. Registering node3..."
curl -s -X POST "$SERVER/register" \
    -H "Content-Type: application/json" \
    -d '{
        "hostname": "gateway-node",
        "ip_address": "10.99.0.103",
        "mac_address": "52:54:00:aa:bb:03",
        "cpus": 2,
        "memory_mb": 4096,
        "disk_gb": 100,
        "metadata": {
            "rack": "A1",
            "role": "gateway"
        }
    }' | jq .
echo ""

# List all nodes
echo "5. List all discovered nodes..."
curl -s "$SERVER/nodes" | jq .
echo ""

# Get specific node
echo "6. Get node-0001 details..."
curl -s "$SERVER/nodes/node-0001" | jq .
echo ""

# Re-register node (update)
echo "7. Re-register node1 (should update, not create new)..."
curl -s -X POST "$SERVER/register" \
    -H "Content-Type: application/json" \
    -d '{
        "hostname": "compute-node-1-updated",
        "ip_address": "10.99.0.101",
        "mac_address": "52:54:00:aa:bb:01",
        "cpus": 16,
        "memory_mb": 32768,
        "disk_gb": 1000,
        "metadata": {
            "rack": "A1",
            "role": "compute",
            "upgraded": "true"
        }
    }' | jq .
echo ""

# List all nodes again
echo "8. List all nodes (should still be 3)..."
curl -s "$SERVER/nodes" | jq '.count'
echo ""

# Delete a node
echo "9. Delete node-0003..."
curl -s -X DELETE "$SERVER/nodes/node-0003" | jq .
echo ""

# Final list
echo "10. Final node list..."
curl -s "$SERVER/nodes" | jq .

echo ""
echo "=== Test Complete ==="
