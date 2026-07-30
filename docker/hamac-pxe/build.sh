#!/bin/bash
# Build de l'image hamac-pxe.
#
# Récupère les fichiers boot depuis tools/discovery-prototype/tftp/
# (vmlinuz + initramfs-hybrid.gz, ~40 MB total) vers le contexte Docker,
# build l'image, puis valide qu'elle démarre proprement (dnsmasq parse la conf
# générée par entrypoint sans crash).
#
# Usage:
#   ./build.sh [tag]
#   PXE_BASE_IMAGE=debian:bookworm-slim ./build.sh   # override la base
#                                                     # (défaut : ubuntu:noble,
#                                                     #  cf. Dockerfile)
#
# Tag par défaut : registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_TFTP="$PROJECT_ROOT/tools/discovery-prototype/tftp"

TAG="${1:-registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0}"
LATEST_TAG="${TAG%:*}:latest"
BUILD_ARGS=()
[ -n "${PXE_BASE_IMAGE:-}" ] && BUILD_ARGS+=(--build-arg "PXE_BASE_IMAGE=${PXE_BASE_IMAGE}")

# ---- 1. Vérification des prérequis -----------------------------------------
missing=""
for f in vmlinuz initramfs-hybrid.gz; do
  [ -f "$SRC_TFTP/$f" ] || missing="$missing $f"
done
if [ -n "$missing" ]; then
  cat >&2 <<EOF
ERROR: fichier(s) manquant(s) dans $SRC_TFTP :$missing

Pour les régénérer :
  - vmlinuz : voir $SRC_TFTP/README.md (noyau du netboot installer Debian)
  - initramfs-hybrid.gz : ./tools/discovery-prototype/e2e-hamac-test.sh
    (regénère l'initramfs avec le init courant au début du smoke test)
EOF
  exit 1
fi

# ---- 2. Copie dans le contexte Docker --------------------------------------
echo "==> Copie des fichiers boot vers le contexte Docker..."
mkdir -p "$SCRIPT_DIR/tftp"
cp "$SRC_TFTP/vmlinuz"             "$SCRIPT_DIR/tftp/vmlinuz"
cp "$SRC_TFTP/initramfs-hybrid.gz" "$SCRIPT_DIR/tftp/initramfs-hybrid.gz"

# Cleanup automatique des artefacts copiés en sortie (succès ou échec).
# Ils sont .gitignored mais on les enlève quand même pour garder le repo propre.
trap 'rm -f "$SCRIPT_DIR/tftp/vmlinuz" "$SCRIPT_DIR/tftp/initramfs-hybrid.gz"' EXIT

# ---- 3. Build de l'image ---------------------------------------------------
echo "==> docker build $TAG ..."
docker build "${BUILD_ARGS[@]}" -t "$TAG" -t "$LATEST_TAG" "$SCRIPT_DIR"

SIZE_BYTES=$(docker image inspect "$TAG" --format '{{.Size}}')
SIZE_MB=$(( SIZE_BYTES / 1024 / 1024 ))
echo "    -> $TAG  (~${SIZE_MB} MB)"

# ---- 4. Smoke test : entrypoint génère la conf, dnsmasq parse OK -----------
# On lance le container quelques secondes avec --rm. dnsmasq doit démarrer
# sans erreur fatale. On ne peut pas tester le broadcast DHCP dans cet env
# (Docker default networking n'expose pas le L2 au broadcast LAN). Le vrai
# test passera par network_mode: host sur socrates.
echo "==> Smoke test (boot dnsmasq 3s, vérifie pas de crash) ..."
LOGS=$(timeout 3 docker run --rm \
  -e INTERFACE=lo \
  -e LISTEN_ADDRESS=127.0.0.1 \
  -e DISCOVERY_URL=http://example.invalid:8877 \
  -e ALLOWED_MACS="" \
  "$TAG" 2>&1 || true)

if echo "$LOGS" | grep -qE "starting dnsmasq|dnsmasq.*started"; then
  echo "    -> entrypoint OK, dnsmasq lancé"
else
  echo "    -> WARNING: pas de trace 'starting dnsmasq' dans les logs."
  echo "$LOGS" | head -20
fi

if echo "$LOGS" | grep -qiE "fatal|cannot|invalid option"; then
  echo "$LOGS" >&2
  echo "    -> FAIL : dnsmasq a refusé la conf" >&2
  exit 1
fi

# ---- 5. Récap --------------------------------------------------------------
cat <<EOF

==> Build OK : $TAG

Déploiement (en network_mode: host sur le Swarm, cf. doc/OCPSI_DEPLOY_PLAN.md) :
  docker run --network host --cap-add NET_ADMIN \\
    -e INTERFACE=eth0 \\
    -e DISCOVERY_URL=http://socrates.ocp.local:8877 \\
    -e ALLOWED_MACS=aa:bb:cc:dd:ee:ff \\
    $TAG

Push :
  docker push $TAG && docker push $LATEST_TAG
EOF
