#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
#
# Recopie dans doc/assets/logo/ les logos du dépôt de marque
# (forge.ocamlpro.com/OSS/hamac-brand), qui fait référence, et note le commit
# d'où ils viennent dans doc/assets/logo/SOURCE.md.
#
#   tools/sync-brand.sh [chemin d'un clone de hamac-brand]   (défaut : ../hamac-brand)
#
# Seuls les fichiers déjà présents dans doc/assets/logo/ sont recopiés : le
# dépôt ne garde que ce qu'il utilise.
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
brand="${1:-$here/../hamac-brand}"
dest="$here/doc/assets/logo"

[ -d "$brand/logo" ] || { echo "pas de dépôt de marque dans $brand" >&2; exit 1; }
if [ -n "$(git -C "$brand" status --porcelain -- logo)" ]; then
  echo "$brand/logo a des modifications non commitées : commiter dans hamac-brand d'abord" >&2
  exit 1
fi
commit="$(git -C "$brand" rev-parse HEAD)"

for f in "$dest"/*; do
  name="$(basename "$f")"
  [ "$name" = SOURCE.md ] && continue
  [ -f "$brand/logo/$name" ] || { echo "$name absent de hamac-brand/logo" >&2; exit 1; }
  cp "$brand/logo/$name" "$f"
done

cat > "$dest/SOURCE.md" <<MD
<!-- SPDX-License-Identifier: CC-BY-ND-4.0 -->

# Provenance

Copies des logos du dépôt de marque, qui fait référence :
<https://forge.ocamlpro.com/OSS/hamac-brand>, commit \`$commit\`.

Ne pas les modifier ici : les changer dans hamac-brand, puis lancer
\`tools/sync-brand.sh\`. Licence (CC BY-ND 4.0) et politique de marque :
\`LICENSE-ARTWORK.md\` et \`TRADEMARKS.md\` de hamac-brand.
MD
echo "doc/assets/logo/ synchronisé sur hamac-brand@${commit:0:7}"
