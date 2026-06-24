#!/bin/bash
# SIESTE Static Build Script
#
# Compiles SIESTE services as fully static executables using musl.
# Can be run inside Docker or on an Alpine system with opam.
#
# Usage:
#   # From Docker:
#   docker run --rm -v $(pwd):/src sieste-static-builder /src/tools/static-build/build.sh [bundle_dir]
#
#   # On Alpine with opam:
#   ./tools/static-build/build.sh [bundle_dir]

set -e

BUNDLE_DIR="${1:-/src/bundle}"
BUILD_DIR="$BUNDLE_DIR/build"

echo "============================================"
echo "  SIESTE Static Build"
echo "============================================"
echo "Bundle: $BUNDLE_DIR"
echo ""

# Check we're in the right environment
if ! command -v opam &>/dev/null; then
    echo "ERROR: opam not found"
    exit 1
fi

# Ensure we're using opam environment
eval $(opam env)

# Check for musl
if ldd --version 2>&1 | grep -q glibc; then
    echo "WARNING: Running on glibc system"
    echo "For fully static binaries, use Alpine/musl"
    echo "Continuing with partial static linking..."
    STATIC_FLAGS="-cclib -static"
else
    echo "Using musl libc - full static linking enabled"
    STATIC_FLAGS="-cclib -static -cclib -no-pie"
fi

# Find all service directories
if [ ! -d "$BUILD_DIR" ]; then
    echo "ERROR: Build directory not found: $BUILD_DIR"
    exit 1
fi

# Update dune files to use static flags
echo "[*] Configuring static linking..."

for dune_file in "$BUILD_DIR"/*/dune; do
    if [ -f "$dune_file" ]; then
        service_dir=$(dirname "$dune_file")
        service_name=$(basename "$service_dir")

        echo "    Processing: $service_name"

        # Check if already has static flags
        if ! grep -q "cclib.*-static" "$dune_file"; then
            # Add static flags to executable stanza
            sed -i 's/(libraries/(flags (:standard '"$STATIC_FLAGS"'))\n (libraries/' "$dune_file"
        fi
    fi
done

# Build with static linking
echo ""
echo "[*] Building static executables..."
cd "$BUILD_DIR"

# Set environment for static build
export OCAMLPARAM="_,cclib=-static,cclib=-no-pie"

opam exec -- dune build --force 2>&1 | tail -20

# Copy binaries to bin directory
echo ""
echo "[*] Copying binaries..."
mkdir -p "$BUNDLE_DIR/bin"

for exe in "$BUILD_DIR"/_build/default/*/main.exe; do
    if [ -f "$exe" ]; then
        service_name=$(basename $(dirname "$exe"))
        target="$BUNDLE_DIR/bin/$service_name"
        cp "$exe" "$target"
        chmod +x "$target"

        # Verify it's static
        if file "$target" | grep -q "statically linked"; then
            echo "    $service_name: STATIC"
        elif file "$target" | grep -q "static-pie"; then
            echo "    $service_name: STATIC-PIE"
        else
            echo "    $service_name: dynamic (may not work on Alpine)"
            file "$target"
        fi

        size=$(du -h "$target" | cut -f1)
        echo "    Size: $size"
    fi
done

echo ""
echo "[*] Build complete!"
echo ""

# List binaries
echo "Binaries:"
ls -la "$BUNDLE_DIR/bin/"
