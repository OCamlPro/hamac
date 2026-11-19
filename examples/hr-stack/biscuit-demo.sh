#!/usr/bin/env bash
# Démo Hyper Open X (lot L3) — provider Biscuit de hamac, branche feat/biscuit-provider.
#
# Raconte, pour un public non technique, ce que fait le provider Biscuit :
# à partir des étiquettes de sécurité écrites dans le manifeste LOAF,
# hamac génère la politique de vérification (autoriseur Datalog Biscuit) ;
# un sujet la satisfait ou non, prouvé cryptographiquement sur un jeton signé.
#
# Prérequis : biscuit-cli (`cargo install biscuit-cli`) dans le PATH.
# Le binaire hamac est cherché dans le PATH, ou via HAMAC="dune exec -- hamac"
# (lancer le script depuis un checkout où `dune build` a été fait).
#
# Usage : ./biscuit-demo.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

if [ -n "${HAMAC:-}" ]; then HAMAC_CMD="$HAMAC"
elif command -v hamac >/dev/null 2>&1; then HAMAC_CMD="hamac"
else HAMAC_CMD="dune exec -- hamac"; fi

if ! command -v biscuit >/dev/null 2>&1; then
  echo "prérequis : biscuit-cli dans le PATH (cargo install biscuit-cli)" >&2
  exit 1
fi

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

hr()  { printf '\n\033[1;34m=== %s ===\033[0m\n' "$1"; }
ok()  { printf '\033[1;32m%s\033[0m\n' "$1"; }
ko()  { printf '\033[1;31m%s\033[0m\n' "$1"; }

hr "1. Ce que déclare le manifeste (examples/hr-stack/hr-api.loaf)"
echo "La route /employees/salaries exige un niveau de sécurité, des"
echo "compartiments (besoin d'en connaître) et un rôle :"
echo
sed -n '/route "\/employees\/salaries"/,/^  }/p' examples/hr-stack/hr-api.loaf | sed 's/^/    /'
echo
echo "Le patron exemple_rh déclare les niveaux ordonnés [public, internal,"
echo "confidential] (public=1, internal=2, confidential=3), les compartiments"
echo "rh et finance, et les rôles rh, comptable, admin."

hr "2. hamac en génère la politique de vérification (autoriseur Biscuit)"
$HAMAC_CMD biscuit authorizer examples/hr-stack providers \
  --service hr_api --route /employees/salaries | tee "$W/authorizer.datalog" | sed 's/^/    /'
echo
echo "(hamac biscuit authorizer … : un check par dimension du treillis —"
echo " niveau >= 3, compartiments rh et finance, rôle comptable ou admin.)"

hr "3. Clé de signature de l'émetteur (le service d'auth)"
KP="$(biscuit keypair 2>/dev/null)"
echo "$KP" | grep 'Private key:' | sed 's/.*Private key: *//' > "$W/priv.key"
echo "$KP" | grep 'Public key:'  | sed 's/.*Public key: *//'  > "$W/pub.key"
echo "    paire de clés ed25519 générée ; la clé publique sera celle de la bordure."

# sujet: nom|niveau|compartiments|rôles|attendu|description
SUJETS=(
  "alice|confidential|rh,finance|comptable|allow|comptable, niveau confidentiel, compartiments rh+finance"
  "bob|public||rh|deny|développeur, niveau public, rôle rh"
  "carol|confidential|rh,finance|admin|allow|admin, niveau confidentiel, compartiments rh+finance"
)

hr "4. Trois sujets se présentent : le jeton est émis, signé, puis vérifié en bordure"
declare -a RES=()
i=0
for s in "${SUJETS[@]}"; do
  IFS='|' read -r name level cats roles attendu desc <<< "$s"
  i=$((i+1))
  echo
  echo "  sujet $i/3 : $name — $desc"
  # le bloc autorité (clearance du sujet) est généré par hamac, signé par l'émetteur
  $HAMAC_CMD biscuit token examples/hr-stack providers \
    --user "$name" --level "$level" ${cats:+--categories "$cats"} --roles "$roles" \
    2>/dev/null | biscuit generate --private-key-file "$W/priv.key" - > "$W/$name.bc" 2>/dev/null
  echo "    jeton émis par hamac et signé (ed25519) : $(wc -c < "$W/$name.bc") octets"
  if biscuit inspect --public-key-file "$W/pub.key" \
       --authorize-with-file "$W/authorizer.datalog" "$W/$name.bc" >/dev/null 2>&1; then
    got=allow; verdict="✓ AUTORISÉ (la requête atteint le service)"
  else
    got=deny;  verdict="✗ REFUSÉ en bordure (403, le service n'est jamais atteint)"
  fi
  if [ "$got" = "$attendu" ]; then ok "    décision : $verdict — conforme au manifeste ✓"
  else ko "    décision : $verdict — ATTENDU : $attendu ✗"; fi
  RES+=("$name|$desc|$got|$attendu")
done

hr "5. Bilan"
pass=0
for r in "${RES[@]}"; do
  IFS='|' read -r name desc got attendu <<< "$r"
  [ "$got" = "$attendu" ] && pass=$((pass+1))
  printf '    %-6s %-52s bordure=%-6s attendu=%-6s\n' "$name" "$desc" "$got" "$attendu"
done
echo
echo "  $pass/3 décisions conformes au treillis déclaré dans le manifeste."
echo
echo "  En production, cette vérification a lieu en bordure, dans Sozu :"
echo "  hamac sozu config génère la configuration de routage (voir le POC"
echo "  Hyper Open X pour la chaîne complète Sozu → validateur Biscuit → service)."
[ "$pass" -eq 3 ]
