Catalogue des erreurs du validateur (spécification du format de manifeste,
section « Validation ») : chaque code que Hamac produit a un cas dans
`cases/<code>-<sujet>/`. Le validateur doit le refuser, avec `--strict` pour
les avertissements, et le diagnostic doit porter ce code. Pour chaque cas, on
montre le diagnostic attendu : la suite tient lieu de documentation des
messages.

Un cas est un ensemble de fichiers LOAF validés ensemble ; les patrons sont
des modules, dans `lib/`. Les fautes que le langage refuse lui-même (syntaxe
mise à part : champ inconnu, valeur hors de sa sorte, référence à un bloc
absent, champ obligatoire absent) portent un code `L…` de LOAF, testé par
LOAF, et n'ont pas de cas ici.

  $ for d in cases/*/; do
  >   c=$(basename "$d"); code=${c%%-*}
  >   lib=; [ -d "$d/lib" ] && lib="-L lib"
  >   out=$(cd "$d" && hamac validate --strict $lib *.loaf 2>&1); rc=$?
  >   line=$(printf '%s\n' "$out" | grep -F "[$code]" | head -n 1 | sed 's/^hamac: \[[A-Z]*\] //')
  >   if [ "$rc" -ne 0 ] && [ -n "$line" ]; then echo "$line"; else echo "$c: NOT REFUSED"; printf '%s\n' "$out"; fi
  > done
  manifest.loaf:7:1: [E001] syntax error before '}'; expected, among others: '.' ending an instruction, ':-', ',' or ';'
  manifest.loaf:5:1: [E004] service un_nom_de_service_bien_trop_long_pour_tenir_dans_une_etiquette_dns: its host name un-nom-de-service-bien-trop-long-pour-tenir-dans-une-etiquette-dns is not a DNS label (1 to 63 lowercase letters, digits and '_' in the name, '_' neither first nor last)
  manifest.loaf:5:1: [E006] min_replicas and max_replicas go together
  manifest.loaf:12:3: [E007] reference 'sans-backend' of secret key: expected <backend>:<path>[#<key>]
  manifest.loaf:7:3: [E008] the artifact of web is not an OCI image: it runs on exactly one architecture
  manifest.loaf:18:5: [E009] node worker of lab is arm64, but its profile station installs a system for amd64
  manifest.loaf:7:3: [E011] sha256 of the artifact of web: expected 64 hexadecimal characters
  manifest.loaf:11:3: [E012] bundle 'base' listed twice
  manifest.loaf:11:3: [E013] consumes db of web: exactly one of capability and service
  manifest.loaf:11:3: [E014] memory_request of web above its memory_limit
  manifest.loaf:11:3: [E016] expected 1 <= min_replicas <= max_replicas
  manifest.loaf:11:3: [E020] environment TOKEN of web refers to an undeclared secret
  stack.loaf:7:5: [E022] the stack overrides consumes cache, which web does not declare
  web.loaf:11:3: [E023] consumes db of web: no provider of capability database, or several without a choice by the stack
  manifest.loaf:11:3: [E024] db provides the capability database without a database block
  manifest.loaf:12:5: [E031] mount 'data' of volume data is not an absolute path
  manifest.loaf:11:3: [E032] size is required for the persistent volume data
  manifest.loaf:11:3: [E033] local volume 'data' has neither 'backup' nor 'rebuild': decide what happens to its data when the node is lost
  manifest.loaf:11:3: [E034] secret key of web: exactly one of ref and generate
  manifest.loaf:12:32: [E035] port 9090 is not declared by port
  portal.loaf:12:16: [E040] portal (zone public) cannot consume vault (zone secure): the security model of the patterns does not let zone public read zone secure; if vault must expose data to zone public, have it push them to a service of that zone
  high.loaf:12:19: [E041] analyst (zone high) consumes sensor (zone low) across a diode: nothing can answer a request through it; declare the flow mode push, sensor sending what analyst receives
  web.loaf:11:3: [E042] zone dmz of web is not defined by the patterns
  manifest.loaf:14:5: [E043] route /health is public: it cannot also require roles
  web.loaf:13:20: [E044] route /vault is classified secure, above zone internal of web (internal): a service holds no data more sensitive than its zone
  manifest.loaf:13:20: [E045] route /admin of web requires the role admn, which no pattern declares
  manifest.loaf:20:3: [E046] the infrastructure lab has no node of the zone of web for one of its architectures
  lib/b.loaf:8:3: [E050] the levels of b differ from those of another pattern of the set
  lib/b.loaf:8:13: [E051] zone rh is already defined with another label
  manifest.loaf:6:19: [E052] constraint c1 of p: unsafe variables: 'X' is unsafe
  manifest.loaf:11:3: [W001] 'placement' is experimental: its meaning may change in a minor version (write accept_experimental in the stack to acknowledge)
  manifest.loaf:5:1: [W002] the stack has no services
  web.loaf:5:1: [W003] service web is defined in web-prod.loaf and web.loaf
  manifest.loaf:7:3: [W010] OCI image 'registry.example.org/web:latest' of web is not pinned by digest (@sha256:…)
  manifest.loaf:11:3: [W011] health check of web: timeout is not shorter than interval
  manifest.loaf:11:3: [W012] environment DB_PASSWORD of web looks like a literal secret: declare it as a secret
  manifest.loaf:5:1: [W013] no bundles and no cloud_init_extra: nothing will happen at provision time
