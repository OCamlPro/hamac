#!/bin/bash
# Build local du binaire OCaml puis docker build de l'image hamac-discovery.
#
# Usage:
#   ./build.sh [tag]
#
# Tag défaut: registry.ocamlpro.com/ocamlpro/hamac/hamac-discovery:0.1.0
#
# Le binaire OCaml est compilé localement (besoin d'opam) puis copié dans le
# contexte Docker. Le Dockerfile ne fait que packager.
#
# IMPORTANT (glibc) : le binaire est lié dynamiquement à la glibc de la
# machine de build. L'image runtime est debian:bookworm-slim (glibc 2.36).
# Si tu builds sur une distro plus récente (glibc > 2.36), le binaire ne
# tournera PAS dans l'image ("GLIBC_2.xx not found"). En CI ce n'est pas un
# souci : le job binary tourne dans ocaml/opam:debian-12 (bookworm, 2.36).
# Pour un test local d'image fidèle, compiler le binaire dans un conteneur
# debian:bookworm, ou tester le binaire natif directement (hors Docker).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TAG="${1:-registry.ocamlpro.com/ocamlpro/hamac/hamac-discovery:0.1.0}"
LATEST_TAG="${TAG%:*}:latest"

echo "==> Building discovery_server binary (release mode)..."
cd "$PROJECT_ROOT"
opam exec -- dune build --profile=release pkgs/hamac-discovery

BIN="$PROJECT_ROOT/_build/default/pkgs/hamac-discovery/main.exe"
if [ ! -f "$BIN" ]; then
    echo "ERROR: binary not found at $BIN" >&2
    exit 1
fi

echo "==> Binary: $BIN ($(du -h "$BIN" | cut -f1))"

# Copie dans le contexte Docker (le Dockerfile fait COPY) :
#  - le binaire
#  - les bundles (templates cloud-init + schémas de params)
#  - les profils built-in (seed du catalogue)
cp "$BIN" "$SCRIPT_DIR/discovery_server.exe"
rm -rf "$SCRIPT_DIR/bundles" "$SCRIPT_DIR/profiles"
cp -r "$PROJECT_ROOT/templates/bundles"        "$SCRIPT_DIR/bundles"
cp -r "$PROJECT_ROOT/provisioning-profiles"    "$SCRIPT_DIR/profiles"
trap 'rm -rf "$SCRIPT_DIR/discovery_server.exe" "$SCRIPT_DIR/bundles" "$SCRIPT_DIR/profiles"' EXIT

echo "==> docker build $TAG ..."
docker build -t "$TAG" -t "$LATEST_TAG" "$SCRIPT_DIR"

echo ""
echo "==> Built:"
docker image inspect "$TAG" --format '  {{.RepoTags}}  size={{.Size}} bytes'
echo ""
echo "==> Test it locally:"
echo "  docker run --rm -p 18877:8877 \\"
echo "    -v /tmp/hamac-state:/var/lib/hamac-discovery \\"
echo "    $TAG"
echo ""
echo "  curl http://localhost:18877/health"
echo ""
echo "==> Push:"
echo "  docker push $TAG && docker push $LATEST_TAG"
