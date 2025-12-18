#!/bin/bash
# Build minimal PXE boot image for SIESTE discovery
#
# This creates a tiny Linux initramfs that:
# 1. Boots via PXE
# 2. Configures network via DHCP
# 3. Registers itself with the discovery server
# 4. Waits for instructions

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/pxe-build"
OUTPUT_DIR="$SCRIPT_DIR/tftp"
DISCOVERY_SERVER="${DISCOVERY_SERVER:-10.99.0.1:8877}"

echo "=== SIESTE PXE Image Builder ==="
echo "Discovery server: $DISCOVERY_SERVER"

# Check for required tools
for cmd in curl cpio gzip; do
    if ! command -v $cmd &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

# Create build directory
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"/{bin,sbin,etc,proc,sys,dev,tmp,root}
mkdir -p "$OUTPUT_DIR"

# Create the init script
cat > "$BUILD_DIR/init" << 'INIT_EOF'
#!/bin/busybox sh

# Mount essential filesystems
/bin/busybox mount -t proc none /proc
/bin/busybox mount -t sysfs none /sys
/bin/busybox mount -t devtmpfs none /dev

# Create busybox symlinks
/bin/busybox --install -s /bin

# Set hostname
HOSTNAME="sieste-node-$$"
hostname "$HOSTNAME"

echo "============================================"
echo "SIESTE Infrastructure Discovery Agent"
echo "============================================"
echo ""

# Wait for network interface
echo "Waiting for network interface..."
sleep 2

# Try to find network interface
IFACE=""
for iface in eth0 ens3 enp0s3; do
    if [ -d "/sys/class/net/$iface" ]; then
        IFACE="$iface"
        break
    fi
done

if [ -z "$IFACE" ]; then
    echo "ERROR: No network interface found"
    ls /sys/class/net/
    exec /bin/sh
fi

echo "Found interface: $IFACE"

# Get MAC address
MAC=$(cat /sys/class/net/$IFACE/address)
echo "MAC Address: $MAC"

# Configure network via DHCP
echo "Configuring network via DHCP..."
udhcpc -i "$IFACE" -q -n -t 5 2>/dev/null || {
    echo "DHCP failed, trying manual config..."
    ip link set "$IFACE" up
    ip addr add 10.99.0.100/24 dev "$IFACE"
    ip route add default via 10.99.0.1
}

# Get IP address
IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "IP Address: $IP"

# Get system info
CPUS=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
MEM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_MB=$((MEM_KB / 1024))

echo ""
echo "System Info:"
echo "  CPUs: $CPUS"
echo "  Memory: ${MEM_MB}MB"
echo ""

# Discovery server (passed via kernel command line or default)
DISCOVERY_SERVER=$(cat /proc/cmdline | grep -oP 'sieste.discovery=\K[^\s]+' || echo "http://10.99.0.1:8877")

echo "Registering with discovery server: $DISCOVERY_SERVER"

# Build JSON payload
JSON=$(cat << EOF
{
    "hostname": "$HOSTNAME",
    "ip_address": "$IP",
    "mac_address": "$MAC",
    "cpus": $CPUS,
    "memory_mb": $MEM_MB,
    "disk_gb": 10,
    "metadata": {
        "boot_method": "pxe",
        "kernel": "$(uname -r 2>/dev/null || echo 'minimal')"
    }
}
EOF
)

echo "Payload:"
echo "$JSON"
echo ""

# Register with server using wget (busybox)
echo "Sending registration..."
RESULT=$(wget -q -O - --header="Content-Type: application/json" --post-data="$JSON" "${DISCOVERY_SERVER}/register" 2>&1) && {
    echo "Registration successful!"
    echo "Response: $RESULT"
} || {
    echo "Registration failed: $RESULT"
    echo "Retrying in 10 seconds..."
    sleep 10
    # Retry once
    wget -q -O - --header="Content-Type: application/json" --post-data="$JSON" "${DISCOVERY_SERVER}/register" || true
}

echo ""
echo "============================================"
echo "Node registered. Entering shell for debug..."
echo "Type 'poweroff' to shutdown."
echo "============================================"
exec /bin/sh
INIT_EOF

chmod +x "$BUILD_DIR/init"

# Download busybox static binary if not present
BUSYBOX="$BUILD_DIR/bin/busybox"
if [ ! -f "$BUSYBOX" ]; then
    echo "Downloading busybox static binary..."
    BUSYBOX_URL="https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
    curl -L -o "$BUSYBOX" "$BUSYBOX_URL" || {
        echo "Failed to download busybox. Trying alternative..."
        # Try to use system busybox if available
        if command -v busybox &>/dev/null; then
            cp "$(which busybox)" "$BUSYBOX"
        else
            echo "ERROR: Could not find or download busybox"
            exit 1
        fi
    }
    chmod +x "$BUSYBOX"
fi

# Create initramfs
echo "Creating initramfs..."
cd "$BUILD_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip > "$OUTPUT_DIR/initrd.img"

echo ""
echo "PXE image built successfully!"
echo "  Initramfs: $OUTPUT_DIR/initrd.img"
echo ""
echo "Note: You still need a Linux kernel (vmlinuz) to boot."
echo "You can use your distribution's kernel or download one:"
echo "  - Ubuntu: /boot/vmlinuz-*"
echo "  - Or download: curl -LO https://boot.netboot.xyz/ipxe/vmlinuz"
echo ""

# Check for kernel
if [ -f /boot/vmlinuz-* ]; then
    KERNEL=$(ls /boot/vmlinuz-* | head -1)
    echo "Found kernel: $KERNEL"
    echo "Copy it with: cp $KERNEL $OUTPUT_DIR/vmlinuz"
fi
