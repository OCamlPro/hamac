#!/bin/bash
# Dérive un raw disk image compressé zstd + son block map (bmaptool) depuis
# une image qcow2 de référence, pour les installs PXE physiques.
#
# qcow2 reste la référence (c'est ce que consomment les VMs directement) ;
# embarquer qemu-utils complet dans l'initrd hamac-pxe pour convertir un
# qcow2 en direct forcerait une vingtaine de paquets de dépendances
# transitives (TLS/PKCS#11 pour l'essentiel, hors sujet pour une conversion
# locale) — cf. doc/PROVISIONING_SPEC.md §3.1 et
# doc/HAMAC_PXE_FREEZE_INVESTIGATION.md pour le contexte de cette décision.
# `pxe-build/init` écrit alors le disque via `bmaptool copy` (blkdiscard +
# décompression zstd à la volée), qemu-img (buildé statiquement from-source)
# restant un fallback pour les profils/initrd pas encore migrés.
#
# Tourne sur une machine/CI normale (apt-get install qemu-utils zstd
# bmap-tools suffit) — ne tourne JAMAIS dans l'initrd busybox, donc aucune
# des contraintes de taille/staticité côté client ne s'applique ici.
#
# Usage:
#   ./prepare-os-assets.sh <qcow2-url-ou-chemin> <nom-de-sortie> [dossier-de-sortie]
#
# Exemple :
#   ./prepare-os-assets.sh \
#     https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2 \
#     debian-12-genericcloud-amd64 \
#     ./out
#
# Produit dans <dossier-de-sortie> (défaut : .) :
#   <nom-de-sortie>.raw.zst        - disk image raw compressé zstd
#   <nom-de-sortie>.raw.zst.bmap   - block map associé
# Affiche sur stdout le sha256 du .raw.zst, à reporter dans
# provisioning-profiles/*.yaml (champ os.raw_zst_sha256).

set -euo pipefail

if [ $# -lt 2 ]; then
  echo "Usage: $0 <qcow2-url-ou-chemin> <nom-de-sortie> [dossier-de-sortie]" >&2
  exit 1
fi

QCOW2_SRC="$1"
OUT_NAME="$2"
OUT_DIR="${3:-.}"

# ---- 0. Vérification des prérequis -----------------------------------------
for tool in qemu-img zstd bmaptool sha256sum wget; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERREUR: '$tool' introuvable (apt-get install qemu-utils zstd bmap-tools wget)" >&2
    exit 1
  }
done

mkdir -p "$OUT_DIR"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---- 1. Récupération du qcow2 source ---------------------------------------
case "$QCOW2_SRC" in
  http://*|https://*)
    echo "==> Téléchargement de $QCOW2_SRC..."
    QCOW2_PATH="$WORK_DIR/source.qcow2"
    wget -q -O "$QCOW2_PATH" "$QCOW2_SRC"
    ;;
  *)
    QCOW2_PATH="$QCOW2_SRC"
    [ -f "$QCOW2_PATH" ] || { echo "ERREUR: fichier introuvable: $QCOW2_PATH" >&2; exit 1; }
    ;;
esac

# ---- 2. Conversion qcow2 -> raw ---------------------------------------------
echo "==> Conversion qcow2 -> raw..."
RAW_PATH="$WORK_DIR/disk.raw"
qemu-img convert -O raw -p "$QCOW2_PATH" "$RAW_PATH"

# ---- 3. Block map (sur le raw, PAS le zst : bmaptool a besoin de voir les
#         trous/zones creuses du fichier réel, la compression les masque) ---
echo "==> Génération du block map..."
BMAP_PATH="$OUT_DIR/${OUT_NAME}.raw.zst.bmap"
bmaptool create "$RAW_PATH" -o "$BMAP_PATH"

# ---- 4. Compression zstd ----------------------------------------------------
echo "==> Compression zstd..."
RAW_ZST_PATH="$OUT_DIR/${OUT_NAME}.raw.zst"
zstd -19 -T0 -f -o "$RAW_ZST_PATH" "$RAW_PATH"

# ---- 5. Récap ---------------------------------------------------------------
SHA256=$(sha256sum "$RAW_ZST_PATH" | awk '{print $1}')
cat <<EOF

==> Terminé :
  $RAW_ZST_PATH
  $BMAP_PATH

sha256 de ${OUT_NAME}.raw.zst (provisioning-profiles/*.yaml, champ
os.raw_zst_sha256) :
  $SHA256
EOF
