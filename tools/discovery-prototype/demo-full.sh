#!/bin/bash
# SIESTE Full E2E Demo - Complete Zero-Touch Deployment
#
# This script demonstrates the complete SIESTE deployment pipeline:
# 1. Compiles sieste-auth service bundle
# 2. Starts discovery server
# 3. Deploys service to discovery server
# 4. Boots QEMU VM (simulating bare-metal node)
# 5. VM registers with discovery, receives binary via SSE, starts service
# 6. Verifies service is accessible
#
# Prerequisites:
# - opam environment configured
# - QEMU installed
# - curl installed
#
# Usage: ./demo-full.sh [clean|status|stop|help]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Configuration
DISCOVERY_PORT=8877
SERVICE_PORT=8081
VM_FORWARD_PORT=8082
QEMU_LOG="/tmp/sieste-demo-qemu.log"
SEED_LOG="/tmp/sieste-demo-seed.log"
BUNDLE_DIR="/tmp/sieste-auth-bundle"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_check() { echo -e "${CYAN}[CHECK]${NC} $1"; }

# Cleanup function
cleanup() {
    pkill -f "discovery_server.exe" 2>/dev/null || true
    pkill -f "qemu-system.*sieste" 2>/dev/null || true
}

# Check prerequisites
check_prerequisites() {
    log_step "Checking prerequisites..."

    local missing=""
    for cmd in qemu-system-x86_64 curl jq; do
        if ! command -v $cmd &>/dev/null; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Missing required commands:$missing"
        exit 1
    fi

    # Check opam environment
    if ! opam exec -- true 2>/dev/null; then
        log_error "opam environment not configured. Run: eval \$(opam env)"
        exit 1
    fi

    log_info "All prerequisites met"
}

# Step 1: Build the sieste-auth bundle
build_bundle() {
    log_step "Step 1: Building sieste-auth bundle..."

    cd "$PROJECT_ROOT"

    # Check if auth.zzz exists
    if [ ! -f "stdlib/auth.zzz" ]; then
        log_error "stdlib/auth.zzz not found"
        exit 1
    fi

    # Build SIESTE compiler first
    log_info "Building SIESTE compiler..."
    opam exec -- dune build 2>&1 | tail -5

    # Generate the bundle
    log_info "Generating sieste-auth bundle..."
    rm -rf "$BUNDLE_DIR"

    # Use the bundle generator
    opam exec -- dune exec sieste -- \
        --bundle="$BUNDLE_DIR" \
        --bundle-backends=kubernetes \
        stdlib/auth.zzz 2>&1 | tail -20

    # Check if binary was built
    if [ -f "$BUNDLE_DIR/bin/sieste_auth" ]; then
        local size=$(du -h "$BUNDLE_DIR/bin/sieste_auth" | cut -f1)
        log_info "Bundle built successfully: $BUNDLE_DIR/bin/sieste_auth ($size)"

        # Check binary type for musl/glibc compatibility
        local bin_type=$(file "$BUNDLE_DIR/bin/sieste_auth")
        if echo "$bin_type" | grep -q "dynamically linked"; then
            log_warn "Binary is dynamically linked (requires glibc)"
            log_warn "Alpine VMs use musl - binary may not run"
            log_warn "For production, compile with: dune build --release"
        fi
    else
        log_error "Bundle build failed - binary not found"
        ls -la "$BUNDLE_DIR/" 2>/dev/null || true
        exit 1
    fi
}

# Step 2: Build/update initramfs
build_initramfs() {
    log_step "Step 2: Building initramfs with service agent..."

    local pxe_dir="$SCRIPT_DIR/pxe-build"
    local tftp_dir="$SCRIPT_DIR/tftp"

    # Check if init script exists
    if [ ! -f "$pxe_dir/init" ]; then
        log_error "Init script not found: $pxe_dir/init"
        exit 1
    fi

    # Use hybrid initramfs if it exists (has kernel modules)
    if [ -f "$tftp_dir/initramfs-hybrid.gz" ]; then
        log_info "Updating hybrid initramfs with custom init..."

        local tmp_dir=$(mktemp -d)
        cd "$tmp_dir"

        # Extract
        gunzip -c "$tftp_dir/initramfs-hybrid.gz" | cpio -idm 2>/dev/null

        # Update init script
        cp "$pxe_dir/init" init
        chmod +x init

        # Repack
        find . | cpio -o -H newc 2>/dev/null | gzip > "$tftp_dir/initramfs-hybrid.gz"

        rm -rf "$tmp_dir"
        log_info "Hybrid initramfs updated"
    else
        # Build minimal initramfs
        log_info "Building minimal initramfs..."
        cd "$pxe_dir"
        find . -print | cpio -o -H newc 2>/dev/null | gzip > "$tftp_dir/initramfs-sieste.gz"
        log_warn "Using minimal initramfs (may lack network drivers)"
    fi

    cd "$PROJECT_ROOT"
}

# Step 3: Start discovery server
start_discovery() {
    log_step "Step 3: Starting discovery server..."

    # Kill any existing instance
    pkill -f "discovery_server.exe" 2>/dev/null || true
    sleep 1

    # Check if port is free
    if lsof -i :$DISCOVERY_PORT &>/dev/null; then
        log_error "Port $DISCOVERY_PORT is already in use"
        lsof -i :$DISCOVERY_PORT
        exit 1
    fi

    # Start discovery server
    cd "$PROJECT_ROOT"
    opam exec -- dune exec ./tools/discovery-prototype/discovery-server/discovery_server.exe > "$SEED_LOG" 2>&1 &
    SEED_PID=$!

    log_info "Discovery server starting (PID: $SEED_PID)..."

    # Wait for server to be ready
    for i in {1..30}; do
        if curl -s "http://localhost:$DISCOVERY_PORT/health" | grep -q "ok"; then
            log_info "Discovery server is ready"
            return 0
        fi
        sleep 1
    done

    log_error "Discovery server failed to start"
    cat "$SEED_LOG" | tail -20
    exit 1
}

# Step 4: Deploy service to discovery server
deploy_service() {
    log_step "Step 4: Deploying sieste_auth service..."

    local result=$(curl -s -X POST "http://localhost:$DISCOVERY_PORT/services" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"sieste_auth\",
            \"runtime\": \"http\",
            \"ports\": [$SERVICE_PORT],
            \"replicas\": 1,
            \"binary_path\": \"$BUNDLE_DIR/bin/sieste_auth\"
        }")

    if echo "$result" | grep -q '"name":"sieste_auth"'; then
        log_info "Service registered with discovery server"
        echo "$result" | jq -c '.'
    else
        log_error "Failed to register service: $result"
        exit 1
    fi
}

# Step 5: Start QEMU VM
start_vm() {
    log_step "Step 5: Starting QEMU VM..."

    local tftp_dir="$SCRIPT_DIR/tftp"
    local kernel="$tftp_dir/vmlinuz"
    local initramfs=""

    # Select best initramfs
    if [ -f "$tftp_dir/initramfs-hybrid.gz" ]; then
        initramfs="$tftp_dir/initramfs-hybrid.gz"
        log_info "Using hybrid initramfs (with kernel modules)"
    elif [ -f "$tftp_dir/initramfs-sieste.gz" ]; then
        initramfs="$tftp_dir/initramfs-sieste.gz"
        log_warn "Using minimal initramfs"
    else
        log_error "No initramfs found"
        exit 1
    fi

    if [ ! -f "$kernel" ]; then
        log_error "Kernel not found: $kernel"
        exit 1
    fi

    # Kill any existing VM
    pkill -f "qemu-system.*sieste" 2>/dev/null || true
    sleep 1

    # Start QEMU
    qemu-system-x86_64 \
        -m 512 \
        -kernel "$kernel" \
        -initrd "$initramfs" \
        -append "console=ttyS0 sieste.hostname=auth-node sieste.discovery=http://10.0.2.2:$DISCOVERY_PORT" \
        -nographic \
        -netdev user,id=net0,hostfwd=tcp::$VM_FORWARD_PORT-:$SERVICE_PORT \
        -device e1000,netdev=net0 \
        > "$QEMU_LOG" 2>&1 &

    QEMU_PID=$!
    log_info "QEMU VM starting (PID: $QEMU_PID)..."

    # Wait for VM to register
    log_info "Waiting for VM to boot and register..."
    for i in {1..60}; do
        local nodes=$(curl -s "http://localhost:$DISCOVERY_PORT/nodes" 2>/dev/null | jq -r '.count // 0')
        if [ "$nodes" -gt 0 ]; then
            log_info "VM registered with discovery server"
            return 0
        fi
        sleep 2
    done

    log_warn "VM may not have registered yet. Check $QEMU_LOG for details"
}

# Step 6: Trigger service deployment
trigger_deployment() {
    log_step "Step 6: Triggering service deployment via SSE..."

    # Re-deploy to trigger scheduler now that node is registered
    local result=$(curl -s -X POST "http://localhost:$DISCOVERY_PORT/services" \
        -H "Content-Type: application/json" \
        -d "{
            \"name\": \"sieste_auth\",
            \"runtime\": \"http\",
            \"ports\": [$SERVICE_PORT],
            \"replicas\": 1,
            \"binary_path\": \"$BUNDLE_DIR/bin/sieste_auth\"
        }")

    log_info "Service deployment triggered"

    # Wait for deployment
    log_info "Waiting for service to deploy (this may take up to 60s)..."
    for i in {1..60}; do
        # Check QEMU log for deployment status
        if grep -q "Service sieste_auth started" "$QEMU_LOG" 2>/dev/null; then
            log_info "Service deployment successful!"
            return 0
        fi
        if grep -q "Failed to deploy sieste_auth" "$QEMU_LOG" 2>/dev/null; then
            log_error "Service deployment failed"
            log_info "Checking deployment logs..."
            grep -A 10 "Deploying service" "$QEMU_LOG" | head -20
            return 1
        fi
        sleep 1
    done

    log_warn "Deployment status unclear. Check logs:"
    log_warn "  QEMU: $QEMU_LOG"
    log_warn "  Seed: $SEED_LOG"
}

# Step 7: Verify service is accessible
verify_service() {
    log_step "Step 7: Verifying service is accessible..."

    # Test via forwarded port
    log_check "Testing health endpoint..."
    local health=$(curl -s "http://localhost:$VM_FORWARD_PORT/health" 2>/dev/null)
    if echo "$health" | grep -q "ok"; then
        log_info "Health check: OK"
        echo "$health" | jq -c '.' 2>/dev/null || echo "$health"
    else
        log_warn "Health check failed (this is expected if binary has glibc/musl issue)"
        log_info "Checking QEMU log for errors..."
        tail -30 "$QEMU_LOG"
        return 1
    fi

    # Test auth endpoint
    log_check "Testing auth endpoint (alice/admin)..."
    local auth=$(curl -s "http://localhost:$VM_FORWARD_PORT/check?username=alice&level=admin" 2>/dev/null)
    if echo "$auth" | grep -q "authorized"; then
        log_info "Auth check: OK"
        echo "$auth" | jq -c '.' 2>/dev/null || echo "$auth"
    fi

    log_check "Testing auth endpoint (bob/admin)..."
    local auth2=$(curl -s "http://localhost:$VM_FORWARD_PORT/check?username=bob&level=admin" 2>/dev/null)
    if echo "$auth2" | grep -q "authorized"; then
        echo "$auth2" | jq -c '.' 2>/dev/null || echo "$auth2"
    fi
}

# Show status
show_status() {
    echo ""
    echo "=== SIESTE Demo Status ==="
    echo ""

    echo "Discovery Server (port $DISCOVERY_PORT):"
    if curl -s "http://localhost:$DISCOVERY_PORT/health" &>/dev/null; then
        echo -e "  Status: ${GREEN}Running${NC}"
        local nodes=$(curl -s "http://localhost:$DISCOVERY_PORT/nodes" | jq -r '.count // 0')
        local services=$(curl -s "http://localhost:$DISCOVERY_PORT/services" | jq -r 'length // 0')
        echo "  Nodes: $nodes"
        echo "  Services: $services"
    else
        echo -e "  Status: ${RED}Not running${NC}"
    fi
    echo ""

    echo "QEMU VM:"
    if pgrep -f "qemu-system.*sieste" &>/dev/null; then
        echo -e "  Status: ${GREEN}Running${NC}"
        echo "  Log: $QEMU_LOG"
    else
        echo -e "  Status: ${RED}Not running${NC}"
    fi
    echo ""

    echo "Service (port $VM_FORWARD_PORT):"
    if curl -s "http://localhost:$VM_FORWARD_PORT/health" &>/dev/null; then
        echo -e "  Status: ${GREEN}Running${NC}"
    else
        echo -e "  Status: ${RED}Not accessible${NC}"
    fi
    echo ""
}

# Stop all components
stop_all() {
    log_step "Stopping all demo components..."
    cleanup
    log_info "Demo stopped"
}

# Usage
usage() {
    cat << EOF
SIESTE Full E2E Demo

Usage: $0 [command]

Commands:
    (default)   Run full demo pipeline
    status      Show status of all components
    stop        Stop all running components
    clean       Stop and clean up all artifacts
    help        Show this help message

The demo will:
1. Build the sieste-auth service bundle
2. Start the discovery server
3. Deploy the service configuration
4. Boot a QEMU VM
5. VM registers and receives service via SSE
6. Verify the service is running

Logs:
    QEMU: $QEMU_LOG
    Seed: $SEED_LOG

EOF
}

# Main
case "${1:-run}" in
    run)
        echo ""
        echo "============================================"
        echo "  SIESTE Full E2E Demo"
        echo "============================================"
        echo ""

        trap cleanup EXIT

        check_prerequisites
        build_bundle
        build_initramfs
        start_discovery
        deploy_service
        start_vm
        sleep 5  # Give VM time to connect to SSE
        trigger_deployment
        sleep 10  # Give service time to start
        verify_service

        echo ""
        echo "============================================"
        echo "  Demo Complete"
        echo "============================================"
        echo ""
        echo "Access points:"
        echo "  - Discovery API: http://localhost:$DISCOVERY_PORT"
        echo "  - Dashboard:     http://localhost:$DISCOVERY_PORT/dashboard"
        echo "  - Auth Service:  http://localhost:$VM_FORWARD_PORT"
        echo ""
        echo "Test commands:"
        echo "  curl http://localhost:$VM_FORWARD_PORT/health"
        echo "  curl 'http://localhost:$VM_FORWARD_PORT/check?username=alice&level=admin'"
        echo ""
        echo "Logs:"
        echo "  tail -f $QEMU_LOG"
        echo "  tail -f $SEED_LOG"
        echo ""
        ;;
    status)
        show_status
        ;;
    stop)
        stop_all
        ;;
    clean)
        stop_all
        rm -rf "$BUNDLE_DIR"
        rm -f "$QEMU_LOG" "$SEED_LOG"
        log_info "Cleanup complete"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
