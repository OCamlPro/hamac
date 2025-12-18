#!/bin/bash
# Setup PXE boot files for SIESTE discovery prototype
# Downloads syslinux/pxelinux and creates boot configuration

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TFTP_DIR="$SCRIPT_DIR/tftp"
PXELINUX_DIR="$TFTP_DIR/pxelinux.cfg"

echo "=== SIESTE Discovery - Setting up PXE files ==="

mkdir -p "$TFTP_DIR"
mkdir -p "$PXELINUX_DIR"

# Check for syslinux package
if ! command -v pxelinux.0 &>/dev/null; then
    # Try to find pxelinux in common locations
    PXELINUX=""
    for path in /usr/lib/PXELINUX/pxelinux.0 /usr/share/syslinux/pxelinux.0 /usr/lib/syslinux/pxelinux.0; do
        if [ -f "$path" ]; then
            PXELINUX="$path"
            break
        fi
    done

    if [ -z "$PXELINUX" ]; then
        echo "pxelinux.0 not found. Install syslinux package:"
        echo "  Ubuntu/Debian: sudo apt install pxelinux syslinux-common"
        echo "  Fedora/RHEL:   sudo dnf install syslinux-tftpboot"
        exit 1
    fi
else
    PXELINUX=$(which pxelinux.0)
fi

echo "Found pxelinux at: $PXELINUX"

# Copy required files
SYSLINUX_DIR=$(dirname "$PXELINUX")
cp "$PXELINUX" "$TFTP_DIR/"

# Copy additional modules if available
for module in ldlinux.c32 libutil.c32 menu.c32 libcom32.c32; do
    for path in "$SYSLINUX_DIR/$module" "/usr/lib/syslinux/modules/bios/$module" "/usr/share/syslinux/$module"; do
        if [ -f "$path" ]; then
            cp "$path" "$TFTP_DIR/"
            break
        fi
    done
done

# Create simple PXE boot menu
cat > "$PXELINUX_DIR/default" << 'EOF'
DEFAULT sieste-register
TIMEOUT 30
PROMPT 0

LABEL sieste-register
    KERNEL vmlinuz
    APPEND initrd=initrd.img ip=dhcp sieste.discovery=http://10.99.0.1:8877/register quiet

LABEL local
    LOCALBOOT 0
EOF

echo ""
echo "PXE files installed in $TFTP_DIR:"
ls -la "$TFTP_DIR/"
echo ""
echo "NOTE: You still need a Linux kernel (vmlinuz) and initrd for actual boot."
echo "For testing, we'll use iPXE or a minimal Linux image."
echo ""
echo "For a quick test without full Linux, use iPXE:"
echo "  wget http://boot.ipxe.org/ipxe.pxe -O $TFTP_DIR/pxelinux.0"
