# SIESTE PXE Build - Initramfs Source

This directory contains the source files for building the SIESTE infrastructure discovery initramfs.

## Structure

```
pxe-build/
├── bin/
│   └── busybox     # Static busybox (download manually)
├── dev/            # Device nodes (created at runtime)
├── etc/            # Configuration files
├── init            # SIESTE registration init script
├── proc/           # Mounted at runtime
├── root/           # Root home
├── sbin/           # System binaries
├── sys/            # Mounted at runtime
└── tmp/            # Temporary files
```

## Setup

### 1. Download busybox

```bash
# Download static busybox for x86_64
cd bin
wget https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x busybox
```

### 2. Build minimal initramfs

```bash
cd /path/to/pxe-build
find . | cpio -ov --format=newc | gzip -9 > ../tftp/initramfs-sieste.gz
```

## Notes

- The `init` script is designed for busybox compatibility (no bash-isms)
- Uses `grep -P` alternatives (case statements) for cmdline parsing
- Targets e1000 NIC driver for best QEMU compatibility
- For production, use the hybrid initramfs with Alpine kernel modules
