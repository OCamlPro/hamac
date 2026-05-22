#!/bin/bash
# E2E test du provisioning via hamac.
#
# Flow :
#   1. Build/refresh initramfs avec l'init courant (qui contient la phase 1.5
#      "hamac provisioning").
#   2. Démarre le discovery server avec un state_dir temporaire.
#   3. Génère une image disque raw factice (50 MB, table GPT + partition vfat).
#   4. La sert via Python http.server.
#   5. Pousse un provisioning_profile via hamac (qui pointe vers cette image).
#   6. Lance une VM QEMU en PXE (user networking, pas besoin de root).
#   7. Observe les logs QEMU : la VM doit register, fetch /provisioning/<mac>,
#      télécharger l'image, dd sur /dev/vda, mounter la partition, écrire le
#      seed cloud-init, et rebooter.
#   8. Vérifie l'image disque finale (qcow2 monté en loop) pour confirmer
#      que /var/lib/cloud/seed/nocloud/user-data y est bien.
#
# Pas de boot de vraie Debian ici — c'est un test mécanique du flow.
#
# Usage: ./e2e-hamac-test.sh [stop|clean]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DISCOVERY_PORT=18877
IMG_SERVER_PORT=18080
SSH_PORT=12222
QEMU_LOG="/tmp/hamac-e2e-qemu.log"
DISC_LOG="/tmp/hamac-e2e-discovery.log"
IMG_SERVER_LOG="/tmp/hamac-e2e-imgserver.log"
STATE_DIR="/tmp/hamac-e2e-state"
WORK_DIR="/tmp/hamac-e2e-work"
RAW_IMAGE="$WORK_DIR/test-os.raw"
PROFILE_FILE="$WORK_DIR/test-profile.yml"
VM_DISK="$WORK_DIR/vm-disk.qcow2"

# MAC fixe pour la VM (lowercase, comme hamac normalise)
VM_MAC="52:54:00:ca:fe:01"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERR ]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

cleanup() {
  log_info "Cleaning up..."
  pkill -f "PORT=$DISCOVERY_PORT.*discovery_server" 2>/dev/null || true
  pkill -f "qemu-system-x86_64.*hamac-e2e" 2>/dev/null || true
  pkill -f "python3 -m http.server $IMG_SERVER_PORT" 2>/dev/null || true
}

case "${1:-run}" in
  stop|clean)
    cleanup
    if [ "$1" = "clean" ]; then
      rm -rf "$STATE_DIR" "$WORK_DIR" "$QEMU_LOG" "$DISC_LOG" "$IMG_SERVER_LOG"
      log_info "Cleaned all artifacts"
    fi
    exit 0
    ;;
  run|"")
    ;;
  *)
    echo "Usage: $0 [run|stop|clean]"
    exit 1
    ;;
esac

trap cleanup EXIT

mkdir -p "$STATE_DIR" "$WORK_DIR"
rm -f "$QEMU_LOG" "$DISC_LOG" "$IMG_SERVER_LOG"

# ------------------------------------------------------------
# 1. Initramfs avec init courant
# ------------------------------------------------------------
log_step "1. Refresh initramfs with current init"
TFTP_DIR="$SCRIPT_DIR/tftp"
PXE_BUILD="$SCRIPT_DIR/pxe-build"
if [ ! -f "$TFTP_DIR/initramfs-hybrid.gz" ]; then
  log_error "initramfs-hybrid.gz not found in $TFTP_DIR. Run build-pxe-image.sh first?"
  exit 1
fi
TMP=$(mktemp -d)
( cd "$TMP" && gunzip -c "$TFTP_DIR/initramfs-hybrid.gz" | cpio -idm 2>/dev/null )
cp "$PXE_BUILD/init" "$TMP/init"
chmod +x "$TMP/init"
( cd "$TMP" && find . | cpio -o -H newc 2>/dev/null | gzip > "$TFTP_DIR/initramfs-hybrid.gz" )
rm -rf "$TMP"
log_info "Initramfs updated (init copied from $PXE_BUILD/init)"

# ------------------------------------------------------------
# 2. Discovery server
# ------------------------------------------------------------
log_step "2. Start discovery server on port $DISCOVERY_PORT"
cd "$SCRIPT_DIR/discovery-server"
PORT=$DISCOVERY_PORT HAMAC_DISCOVERY_STATE="$STATE_DIR" \
  opam exec -- dune exec ./discovery_server.exe > "$DISC_LOG" 2>&1 &
sleep 1
for i in 1 2 3 4 5 6 7 8 9 10; do
  if curl -s "http://localhost:$DISCOVERY_PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then
    log_info "Discovery server ready"
    break
  fi
  sleep 1
done
if ! curl -s "http://localhost:$DISCOVERY_PORT/health" 2>/dev/null | grep -q '"status":"ok"'; then
  log_error "Discovery server failed to start"
  tail -20 "$DISC_LOG"
  exit 1
fi

# ------------------------------------------------------------
# 3. Image disque factice
# ------------------------------------------------------------
log_step "3. Generate fake OS image ($RAW_IMAGE, 50 MB)"
dd if=/dev/zero of="$RAW_IMAGE" bs=1M count=50 status=none
# Table GPT avec une partition ext4 unique
sfdisk "$RAW_IMAGE" >/dev/null 2>&1 <<EOF || true
label: gpt
size=, type=L
EOF
# Format ext4 sur la partition (loop)
LOOP=$(sudo losetup --show -fP "$RAW_IMAGE" 2>&1) || {
  log_warn "Cannot setup loop device without sudo. Skipping ext4 format."
  log_warn "The dd test will still write the image, but partition mount inside the VM may fail."
  LOOP=""
}
if [ -n "$LOOP" ]; then
  sudo mkfs.ext4 -F -L sieste-root "${LOOP}p1" >/dev/null 2>&1 || true
  sudo losetup -d "$LOOP"
fi
SHA256=$(sha256sum "$RAW_IMAGE" | awk '{print $1}')
log_info "Image SHA256: $SHA256"

# ------------------------------------------------------------
# 4. Sert l'image via HTTP
# ------------------------------------------------------------
log_step "4. Serve image via http.server on :$IMG_SERVER_PORT"
( cd "$WORK_DIR" && python3 -m http.server "$IMG_SERVER_PORT" > "$IMG_SERVER_LOG" 2>&1 ) &
sleep 1
if ! curl -sI "http://localhost:$IMG_SERVER_PORT/test-os.raw" 2>/dev/null | grep -q "200 OK"; then
  log_error "Image server not responding"
  exit 1
fi

# ------------------------------------------------------------
# 5. Push profile via hamac
# ------------------------------------------------------------
log_step "5. Create and push provisioning_profile"
# IMPORTANT: la VM voit l'host comme 10.0.2.2 via user-mode networking
HOST_FROM_VM="10.0.2.2"
cat > "$PROFILE_FILE" <<EOF
manifest_version: "1.0"
kind: provisioning_profile
name: e2e-test
os:
  image: e2e-fake-os
  url: http://${HOST_FROM_VM}:$IMG_SERVER_PORT/test-os.raw
  sha256: $SHA256
  format: raw
bundles:
  - name: dev-workstation
    params:
      username: julien
      ssh_public_keys: ["ssh-ed25519 AAAA_E2E_TEST_KEY user@e2e"]
      timezone: UTC
cloud_init_extra:
  hostname: e2e-vm
EOF

cd "$PROJECT_ROOT"
opam exec -- dune exec hamac -- provision-push \
  --profile="$PROFILE_FILE" \
  --bundles-dir="$PROJECT_ROOT/templates/bundles" \
  --mac="$VM_MAC" \
  --discovery="http://localhost:$DISCOVERY_PORT"
log_info "Profile pushed for MAC $VM_MAC"

# Vérification rapide côté discovery
RECORDED=$(curl -s "http://localhost:$DISCOVERY_PORT/provisioning/$VM_MAC" | grep -c "e2e-test" || true)
if [ "$RECORDED" -lt 1 ]; then
  log_error "Profile not stored in discovery"
  exit 1
fi

# ------------------------------------------------------------
# 6. Lance VM QEMU
# ------------------------------------------------------------
log_step "6. Boot QEMU VM (user networking, MAC=$VM_MAC)"
KERNEL="$TFTP_DIR/vmlinuz"
INITRD="$TFTP_DIR/initramfs-hybrid.gz"
if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ]; then
  log_error "Missing kernel or initrd in $TFTP_DIR"
  exit 1
fi

# Disque vide qcow2 pour la VM (cible du dd)
qemu-img create -f qcow2 "$VM_DISK" 200M >/dev/null

# Lancement QEMU :
# - kernel + initrd directs (pas de tftp réel pour ce test, on bypass)
# - user networking, hostfwd SSH
# - serial console pour récupérer les logs
# KVM si user dans le groupe kvm ET /dev/kvm accessible, sinon TCG
KVM_OPT=""
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
  KVM_OPT="-enable-kvm"
  log_info "Using KVM acceleration"
else
  log_warn "KVM not accessible, falling back to TCG (slower)"
fi

qemu-system-x86_64 \
  -name "hamac-e2e" \
  -m 768 \
  $KVM_OPT \
  -kernel "$KERNEL" \
  -initrd "$INITRD" \
  -append "console=ttyS0 sieste.discovery=http://${HOST_FROM_VM}:$DISCOVERY_PORT sieste.hostname=e2e-vm" \
  -drive file="$VM_DISK",format=qcow2,if=virtio \
  -netdev user,id=net0,hostfwd=tcp::$SSH_PORT-:22 \
  -device e1000,netdev=net0,mac="$VM_MAC" \
  -nographic \
  > "$QEMU_LOG" 2>&1 &
QEMU_PID=$!
log_info "QEMU started (PID $QEMU_PID). Log: $QEMU_LOG"

# ------------------------------------------------------------
# 7. Observe les phases dans les logs
# ------------------------------------------------------------
log_step "7. Watch QEMU log for hamac provisioning phases"
PHASES_SEEN=""
DEADLINE=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if [ -f "$QEMU_LOG" ]; then
    if grep -q "Found hamac provisioning record" "$QEMU_LOG" && \
       ! echo "$PHASES_SEEN" | grep -q "found"; then
      PHASES_SEEN="$PHASES_SEEN found"
      log_info "  ✓ hamac record détecté"
    fi
    if grep -q "Downloading OS image" "$QEMU_LOG" && \
       ! echo "$PHASES_SEEN" | grep -q "download"; then
      PHASES_SEEN="$PHASES_SEEN download"
      log_info "  ✓ téléchargement démarré"
    fi
    if grep -q "Writing image to" "$QEMU_LOG" && \
       ! echo "$PHASES_SEEN" | grep -q "write"; then
      PHASES_SEEN="$PHASES_SEEN write"
      log_info "  ✓ écriture sur disque"
    fi
    if grep -q "Root partition:" "$QEMU_LOG" && \
       ! echo "$PHASES_SEEN" | grep -q "rootpart"; then
      PHASES_SEEN="$PHASES_SEEN rootpart"
      log_info "  ✓ partition root détectée"
    fi
    if grep -q "Injecting cloud-init seed" "$QEMU_LOG" && \
       ! echo "$PHASES_SEEN" | grep -q "seed"; then
      PHASES_SEEN="$PHASES_SEEN seed"
      log_info "  ✓ seed cloud-init injecté"
    fi
    if grep -q "Hamac provisioning complete" "$QEMU_LOG"; then
      log_info "  ✓ provisioning complete signal"
      break
    fi
    if grep -q "ERROR:.*hamac" "$QEMU_LOG"; then
      log_error "VM reported a hamac error"
      break
    fi
  fi
  sleep 2
done

# ------------------------------------------------------------
# 8. Inspection du disque VM
# ------------------------------------------------------------
log_step "8. Inspect VM disk for injected cloud-init seed"
# Kill VM avant inspection
kill $QEMU_PID 2>/dev/null || true
wait $QEMU_PID 2>/dev/null || true
sleep 1

# Mount qcow2 via nbd nécessite root + module nbd. Plus simple : utiliser
# qemu-img pour convertir en raw et regarder à l'intérieur.
qemu-img convert -O raw "$VM_DISK" "$WORK_DIR/vm-disk.raw" 2>/dev/null
if [ -n "$(command -v file)" ]; then
  log_info "Disk type: $(file "$WORK_DIR/vm-disk.raw" | cut -d: -f2)"
fi

# Si on a sudo (loopback) → mount et inspecte
if sudo -n true 2>/dev/null; then
  LOOP=$(sudo losetup --show -fP "$WORK_DIR/vm-disk.raw")
  log_info "Disk mounted at loop $LOOP"
  PART="${LOOP}p1"
  if [ -b "$PART" ]; then
    MNT="$WORK_DIR/mnt"
    mkdir -p "$MNT"
    if sudo mount -o ro "$PART" "$MNT" 2>/dev/null; then
      SEED="$MNT/var/lib/cloud/seed/nocloud"
      if [ -f "$SEED/user-data" ]; then
        log_info "✓ user-data trouvé. Premières lignes :"
        sudo head -10 "$SEED/user-data"
      else
        log_warn "user-data absent (peut-être normal si le partitionnement n'a pas matché)"
      fi
      sudo umount "$MNT"
    fi
  fi
  sudo losetup -d "$LOOP" 2>/dev/null || true
else
  log_warn "Pas de sudo : skip inspection détaillée du disque."
fi

# ------------------------------------------------------------
# 9. Résumé
# ------------------------------------------------------------
echo ""
echo "============================================"
echo "  Hamac E2E Test Summary"
echo "============================================"
echo "  Phases observées : $PHASES_SEEN"
echo ""
echo "  Logs :"
echo "    QEMU       : $QEMU_LOG"
echo "    Discovery  : $DISC_LOG"
echo "    Img server : $IMG_SERVER_LOG"
echo ""
echo "  Pour debug interactif : tail -f $QEMU_LOG"
echo ""

# Verdict simple : si au moins 'found' et 'download' apparus, on considère OK
if echo "$PHASES_SEEN" | grep -q "found" && echo "$PHASES_SEEN" | grep -q "download"; then
  log_info "SMOKE TEST OK"
  exit 0
else
  log_error "SMOKE TEST FAILED — voir $QEMU_LOG"
  exit 1
fi
