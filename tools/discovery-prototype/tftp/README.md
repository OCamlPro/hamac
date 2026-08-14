# SIESTE PXE Boot Files

This directory contains the boot files for PXE network boot infrastructure discovery.

## Files (not in git - download/build locally)

- `vmlinuz` - Debian netboot installer kernel
- `initramfs-hybrid.gz` - Hybrid initramfs with kernel modules and SIESTE registration

## Setup Instructions

### 1. Download Debian netboot installer kernel and initrd

```bash
URL="https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64"
wget -O vmlinuz "${URL}/linux"
wget -O initrd.gz "${URL}/initrd.gz"
```

(Previously Alpine Linux's `lts` netboot kernel — abandoned after
investigation showed it produces zero console output on a Framework
Laptop 13 (Intel Core Ultra Series 1 / Meteor Lake), a total silent
freeze right at kernel handoff, independent of the PXE/dnsmasq/iPXE
config. Debian's netboot installer kernel boots normally on the same
hardware. See `HAMAC_PXE_FREEZE_INVESTIGATION.md` at the repo root for
the full investigation.)

### 2. Build hybrid initramfs

The hybrid initramfs combines Debian's kernel modules (bundled in its
netboot `initrd.gz`, already matched to this exact kernel) with SIESTE's
custom init script — **plus a static busybox swapped in** (see note below).

```bash
# Create build directory
mkdir -p /tmp/hybrid-initramfs
cd /tmp/hybrid-initramfs

# Extract Debian's netboot initrd (contains kernel modules)
zcat /path/to/initrd.gz | cpio -idmv

# Replace busybox with busybox-static (Debian's installer busybox does NOT
# implement `--install`, which our init script uses to symlink applets
# into /bin and /sbin — under `set -e` this aborted init immediately with
# "Kernel panic - not syncing: Attempted to kill init!". Confirmed and
# fixed via local QEMU testing before this went anywhere near production —
# see HAMAC_PXE_FREEZE_INVESTIGATION.md.)
#
# snapshot.debian.org, not deb.debian.org/.../pool/... : a pool/ URL pinned
# to an exact version still 404s once Debian rebuilds that same version
# (binNMU, `+bN`) and drops the old file from the pool — hit this for real
# in CI. snapshot.debian.org serves a file by its permanent hash instead
# (see .gitlab-ci.yml BUSYBOX_STATIC_URL comment for how to look one up).
wget -O /tmp/busybox-static.deb "https://snapshot.debian.org/file/7c87a0b1d84991b9ebe331f38ddddaaae22fe145"
dpkg-deb -x /tmp/busybox-static.deb /tmp/busybox-extract
cp /tmp/busybox-extract/usr/bin/busybox bin/busybox
chmod +x bin/busybox

# Add NVMe modules (missing from Debian's netboot initrd entirely — not a
# module, not builtin, and not even offered as a debian-installer udeb;
# see .gitlab-ci.yml LINUX_IMAGE_URL comment and
# HAMAC_PXE_FREEZE_INVESTIGATION.md). Pulled from the regular linux-image
# package for the EXACT SAME kernel version (vermagic must match).
wget -O /tmp/linux-image.deb "https://snapshot.debian.org/file/0402b2e2587e557ca9df501c4f627f7a8bc7080f"
dpkg-deb -x /tmp/linux-image.deb /tmp/linux-image-extract
KVER=$(ls lib/modules)
SRC="/tmp/linux-image-extract/usr/lib/modules/${KVER}/kernel/drivers/nvme"
mkdir -p "lib/modules/${KVER}/kernel/drivers/nvme/host" "lib/modules/${KVER}/kernel/drivers/nvme/common"
cp "${SRC}/host/nvme.ko.xz" "${SRC}/host/nvme-core.ko.xz" "lib/modules/${KVER}/kernel/drivers/nvme/host/"
cp "${SRC}/common/nvme-auth.ko.xz" "lib/modules/${KVER}/kernel/drivers/nvme/common/"

# Add zstd + bmaptool + python3 (minimal + stdlib) + their real runtime
# deps, for writing OS images via `bmaptool copy` instead of embarking
# qemu-utils whole (~20 transitive packages, mostly TLS/PKCS#11, irrelevant
# to local qcow2->raw conversion — see doc/PROVISIONING_SPEC.md §3.1 and
# HAMAC_PXE_FREEZE_INVESTIGATION.md). `blkdiscard` is already in the base
# netboot initrd, nothing to add for it. Set determined empirically (via
# readelf -d tracing + a real bmaptool create/copy round-trip test), not
# by trusting each package's declared Depends: (which over-declares —
# e.g. libpython3.13-stdlib also depends on libsqlite3/libncursesw/
# libreadline/libdb for dbm/curses/readline/sqlite3, none of which
# bmaptool ever imports, so none of those are actually needed here).
# All snapshot.debian.org, not deb.debian.org/.../pool/... — see the
# busybox-static note above and .gitlab-ci.yml's LIBLZ4_URL comment for why
# (pool/ URLs pinned to an exact version still rot; snapshot's per-hash
# URLs don't).
mkdir -p /tmp/bmap-extract
for pair in \
  "liblz4:https://snapshot.debian.org/file/366df9ca4cd9a1009c147a612e6526be145a4732" \
  "zstd:https://snapshot.debian.org/file/68018e28d4afac4567e7ef0b4b86aa8cd888734d" \
  "libzstd1:https://snapshot.debian.org/file/96dbb7ea8dced3367f661f31964693f4919c0f9a" \
  "libssl3:https://snapshot.debian.org/file/fa81f709727b16de2a82710bbe0556b58f2b3f50" \
  "python3-minimal:https://snapshot.debian.org/file/9359a1cdee9b7f7b3ffc3615522388e26f64dcbe" \
  "libpython3-minimal:https://snapshot.debian.org/file/6e6e21c2113c1eac1ac300715d71e32e98d09e85" \
  "libpython3-stdlib:https://snapshot.debian.org/file/a1aaebe2d285ecf60729b8444ee5dff26b3fa15c" \
  "bmaptool:https://snapshot.debian.org/file/82685902e669b19c3853e42be863fd94dc1ccf78" \
; do
  name="${pair%%:*}"
  url="${pair#*:}"
  wget -O "/tmp/${name}.deb" "$url"
  dpkg-deb -x "/tmp/${name}.deb" /tmp/bmap-extract
done
BE=/tmp/bmap-extract
cp "$BE/usr/bin/zstd" bin/zstd
cp "$BE"/usr/lib/x86_64-linux-gnu/liblz4.so.1* usr/lib/x86_64-linux-gnu/
cp "$BE"/usr/lib/x86_64-linux-gnu/libzstd.so.1* usr/lib/x86_64-linux-gnu/
cp "$BE"/usr/lib/x86_64-linux-gnu/libssl.so.3* "$BE"/usr/lib/x86_64-linux-gnu/libcrypto.so.3* usr/lib/x86_64-linux-gnu/
cp "$BE/usr/bin/python3.13" usr/bin/python3.13
ln -sf python3.13 usr/bin/python3
cp -r "$BE/usr/lib/python3.13" usr/lib/
cp -r "$BE/usr/lib/python3/dist-packages/bmaptool" usr/lib/python3.13/
cp "$BE/usr/bin/bmaptool" usr/bin/bmaptool
chmod +x usr/bin/bmaptool usr/bin/python3.13 bin/zstd

# Build the static qemu-img fallback (qemu-img-builder stage in
# docker/hamac-pxe/Dockerfile, Alpine/musl, ~10-15 min) and pull it out —
# see that Dockerfile's comment for why it's Alpine/musl rather than the
# same base as the ipxe-builder stage. Build-tested end to end: static-pie
# linked, zero NEEDED entries, `qemu-img convert` works.
docker build --target qemu-img-builder -t qemu-img-builder-tmp /path/to/sieste/docker/hamac-pxe/
QIB_CID=$(docker create qemu-img-builder-tmp)
docker cp "${QIB_CID}:/usr/src/qemu/build/qemu-img" usr/bin/qemu-img
docker rm "${QIB_CID}"
chmod +x usr/bin/qemu-img

# Replace init with SIESTE's version
cp /path/to/sieste/tools/discovery-prototype/pxe-build/init ./init
chmod +x init

# Rebuild initramfs
find . | cpio -ov --format=newc | gzip -9 > /path/to/sieste/tools/discovery-prototype/tftp/initramfs-hybrid.gz
```

### 3. Test with QEMU

```bash
# Run the test script
./tools/seed/scripts/test-pxe-qemu.sh

# Or manually:
qemu-system-x86_64 \
    -m 512 \
    -kernel vmlinuz \
    -initrd initramfs-hybrid.gz \
    -append "console=ttyS0 sieste.discovery=http://10.0.2.2:8877 rdinit=/init" \
    -net nic,model=e1000 \
    -net user \
    -nographic \
    -no-reboot
```

## Technical Details

- **Kernel**: Debian stable's netboot installer kernel (6.12.x as of this
  writing) — general-purpose distro kernel, broad real-hardware support
- **NIC Driver**: e1000 (Intel PRO/1000) - best compatibility
- **Network**: QEMU SLIRP user-mode (10.0.2.0/24, gateway 10.0.2.2)
- **Init**: Custom busybox init script for node registration
- **Registration**: HTTP POST to discovery server with node info

## Boot Flow

1. Kernel boots, loads e1000 module
2. Init script runs, configures network via DHCP
3. Collects system info (hostname, IP, MAC, CPU, RAM)
4. Sends registration request to discovery server
5. Halts after registration

## CI builds (sha256-pinned Debian netboot files)

The GitLab CI (`.gitlab-ci.yml` at the repo root) rebuilds these files from
scratch on every relevant push :
- `vmlinuz` is downloaded from `DEBIAN_NETBOOT_URL` and its sha256 is
  verified against `DEBIAN_LINUX_SHA256`.
- `initramfs-hybrid.gz` is reconstructed by extracting Debian's netboot
  `initrd.gz` (also sha256-verified against `DEBIAN_INITRD_SHA256`),
  replacing its `busybox` with `busybox-static` (sha256-verified against
  `BUSYBOX_STATIC_SHA256` — see the fix note above), adding NVMe modules
  (`LINUX_IMAGE_URL`) and `zstd`/`bmaptool`/`python3` + their runtime deps
  (`LIBLZ4_URL`, `ZSTD_URL`, `LIBZSTD1_URL`, `LIBSSL3_URL`,
  `PYTHON3_MINIMAL_URL`, `LIBPYTHON3_MINIMAL_URL`, `LIBPYTHON3_STDLIB_URL`,
  `BMAPTOOL_URL` — all sha256-verified, same pattern), replacing its
  `/init` by our custom one (`pxe-build/init`), and re-packing.

**When to bump the pinned Debian files** :
- `DEBIAN_NETBOOT_URL` points at Debian's `dists/stable/.../current/`
  path, which tracks the latest stable point release — it **will**
  change content over time (expected, not a bug). CI fails loudly on the
  sha256 check when that happens ; bump `DEBIAN_LINUX_SHA256` /
  `DEBIAN_INITRD_SHA256` after manually validating that the new
  kernel/initrd combination still boots correctly
  (`./tools/discovery-prototype/e2e-hamac-test.sh`, and ideally a real
  PXE boot test on representative hardware given this project's history
  with silent kernel-level freezes).

To get the current shas :
```bash
URL="https://deb.debian.org/debian/dists/stable/main/installer-amd64/current/images/netboot/debian-installer/amd64"
curl -sL "${URL}/linux"     | sha256sum
curl -sL "${URL}/initrd.gz" | sha256sum
```

The `initramfs-hybrid.gz` itself is *not* committed (.gitignore'd) since it
is regenerated by the CI. The `build.sh` scripts in `docker/hamac-pxe/`
provide an equivalent local rebuild for offline iteration.
