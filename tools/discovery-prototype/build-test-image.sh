#!/bin/bash
# Build a minimal test disk image for SIESTE provisioning tests
#
# This creates a small (~50MB) bootable image with:
# - A single ext4 partition
# - cloud-init installed
# - Basic system utilities
#
# For production, use official Ubuntu/Alpine cloud images instead.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="$SCRIPT_DIR/images"
IMAGE_NAME="${1:-test-minimal.img}"
IMAGE_SIZE="${2:-100M}"

echo "=== SIESTE Test Image Builder ==="
echo "Output: $OUTPUT_DIR/$IMAGE_NAME"
echo "Size: $IMAGE_SIZE"
echo ""

# Check for required tools
for cmd in dd mkfs.ext4 mount umount; do
    if ! command -v $cmd &>/dev/null; then
        echo "ERROR: Required command '$cmd' not found"
        exit 1
    fi
done

# Check if running as root (needed for mount/losetup)
if [ "$(id -u)" -ne 0 ]; then
    echo "This script requires root privileges for creating disk images."
    echo "Please run: sudo $0"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

# Create empty disk image
echo "[*] Creating disk image ($IMAGE_SIZE)..."
dd if=/dev/zero of="$IMAGE_NAME" bs=1M count=100 status=progress

# Setup loop device
echo "[*] Setting up loop device..."
LOOP=$(losetup -f --show "$IMAGE_NAME")
echo "    Loop device: $LOOP"

# Create partition table and partition
echo "[*] Creating partition..."
(
echo o      # Create a new empty DOS partition table
echo n      # Add a new partition
echo p      # Primary partition
echo 1      # Partition number
echo        # First sector (default)
echo        # Last sector (default - use all space)
echo a      # Make partition bootable
echo w      # Write changes
) | fdisk "$LOOP" 2>/dev/null || true

# Refresh partition table
partprobe "$LOOP" 2>/dev/null || true
sleep 1

# Create filesystem on partition
PART="${LOOP}p1"
if [ ! -b "$PART" ]; then
    PART="${LOOP}1"
fi
if [ ! -b "$PART" ]; then
    echo "[*] No partition found, using whole disk..."
    PART="$LOOP"
fi

echo "[*] Creating ext4 filesystem on $PART..."
mkfs.ext4 -L sieste-root "$PART"

# Mount and populate
echo "[*] Mounting filesystem..."
MOUNT_DIR=$(mktemp -d)
mount "$PART" "$MOUNT_DIR"

echo "[*] Creating minimal filesystem structure..."
mkdir -p "$MOUNT_DIR"/{bin,sbin,etc,var/lib/cloud/seed/nocloud,proc,sys,dev,tmp,root,home}
mkdir -p "$MOUNT_DIR"/var/log

# Create minimal /etc files
cat > "$MOUNT_DIR/etc/fstab" << 'EOF'
# /etc/fstab - SIESTE minimal image
/dev/root   /           ext4    defaults,noatime    0 1
proc        /proc       proc    defaults            0 0
sysfs       /sys        sysfs   defaults            0 0
devtmpfs    /dev        devtmpfs defaults           0 0
EOF

cat > "$MOUNT_DIR/etc/hostname" << 'EOF'
sieste-node
EOF

cat > "$MOUNT_DIR/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   sieste-node
EOF

# Create a marker file for testing
cat > "$MOUNT_DIR/etc/sieste-image" << EOF
SIESTE Test Image
Built: $(date -Iseconds)
Version: 0.1.0
EOF

# Create placeholder cloud-init directory structure
mkdir -p "$MOUNT_DIR/var/lib/cloud/seed/nocloud"
cat > "$MOUNT_DIR/var/lib/cloud/seed/nocloud/meta-data" << 'EOF'
# Placeholder - will be replaced during provisioning
instance-id: placeholder
local-hostname: sieste-node
EOF

cat > "$MOUNT_DIR/var/lib/cloud/seed/nocloud/user-data" << 'EOF'
#cloud-config
# Placeholder - will be replaced during provisioning
hostname: sieste-node
EOF

# Cleanup
echo "[*] Unmounting..."
sync
umount "$MOUNT_DIR"
rmdir "$MOUNT_DIR"

# Cleanup loop device
echo "[*] Cleaning up loop device..."
losetup -d "$LOOP"

# Compress image
echo "[*] Compressing image..."
gzip -f "$IMAGE_NAME"

FINAL_IMAGE="$IMAGE_NAME.gz"
FINAL_SIZE=$(du -h "$OUTPUT_DIR/$FINAL_IMAGE" | cut -f1)

echo ""
echo "============================================"
echo "  Test image created successfully!"
echo "============================================"
echo "  Image: $OUTPUT_DIR/$FINAL_IMAGE"
echo "  Size: $FINAL_SIZE"
echo ""
echo "To use with discovery server:"
echo "  1. Start server with IMAGES_DIR=$OUTPUT_DIR"
echo "  2. Set image URL: curl -X POST http://localhost:8877/config \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"image_url\": \"http://discovery:8877/images/$FINAL_IMAGE\"}'"
echo ""
