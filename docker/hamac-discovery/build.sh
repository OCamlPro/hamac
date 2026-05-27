#!/bin/bash
# Build local du binaire OCaml puis docker build de l'image hamac-discovery.
#
# Usage:
#   ./build.sh [tag]
#
# Tag défaut: registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:0.1.0
#
# Le binaire OCaml est compilé localement (besoin d'opam + ocamlpro-cli pinned)
# puis copié dans le contexte Docker. Le Dockerfile ne fait que packager.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TAG="${1:-registry.ocamlpro.com/ocamlpro/sieste/hamac-discovery:0.1.0}"
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

# Copie dans le contexte Docker (le Dockerfile fait COPY discovery_server.exe)
cp "$BIN" "$SCRIPT_DIR/discovery_server.exe"
trap 'rm -f "$SCRIPT_DIR/discovery_server.exe"' EXIT

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
