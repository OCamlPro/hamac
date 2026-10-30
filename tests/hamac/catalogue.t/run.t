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
  manifest.loaf:5:1: [E006] min_replicas and max_replicas go together
  manifest.loaf:12:3: [E007] secrets.0.ref: secret reference 'sans-backend' (expected <backend>:<path>[#<key>])
  manifest.loaf:7:3: [E011] artifact.sha256: expected 64 hexadecimal characters (SHA-256)
  manifest.loaf:11:3: [E012] bundles.1: bundle 'base' listed twice
  manifest.loaf:11:3: [E013] consumes db of web: exactly one of capability and service
  manifest.loaf:11:3: [E014] resources.memory_request: request above its limit
  manifest.loaf:11:3: [E016] expected 1 <= min_replicas <= max_replicas
  manifest.loaf:11:3: [E020] environment TOKEN of web refers to an undeclared secret
  stack.loaf:7:5: [E022] the stack overrides consumes cache, which web does not declare
  web.loaf:11:3: [E023] consumes db of web: no provider of capability database, or several without a choice by the stack
  manifest.loaf:11:3: [E024] db provides the capability database without a database block
  manifest.loaf:12:5: [E031] storage.0.mount: mount 'data' is not an absolute path
  manifest.loaf:11:3: [E032] size is required for the persistent volume data
  manifest.loaf:11:3: [E033] storage.0: local volume 'data' has neither 'backup' nor 'rebuild': decide what happens to its data when the node is lost
  manifest.loaf:11:3: [E034] secret key of web: exactly one of ref and generate
  manifest.loaf:12:32: [E035] port 9090 is not declared by port
  portal.loaf: consumes.0: [E040] portal (zone public) cannot consume vault (zone secure): opening a connection to a more sensitive zone is a read up, forbidden by the Bell-LaPadula model. If vault must expose data to zone public, have it push the declassified data to a service of that zone through a declared guard.
  high.loaf: consumes.0: [E041] analyst (zone high) consumes sensor (zone low) across a diode: nothing can answer a request through it. Declare the flow 'mode push', sensor sending what analyst receives.
  web.loaf: security.zone: [E042] zone 'dmz' is not defined by the stack's patterns (zones: public, default, internal, secure)
  manifest.loaf:13:5: [E043] route /health is public: it cannot also require a classification, categories or roles
  web.loaf: security.route_labels.0.classification: [E044] route '/vault' is classified secure, above zone internal (internal): a service holds no data more sensitive than its zone
  lib/b.loaf: lattice.levels: [E050] levels public < internal < secret differ from public < secret declared by another pattern of the stack
  lib/b.loaf: zones.0: [E051] zone 'rh' is already defined with another label or boundary
  manifest.loaf:6:19: [E052] count expects a set, got a host
  manifest.loaf:11:3: [W001] placement: 'placement' is experimental: its meaning may change in a minor version (write accept_experimental in the stack to acknowledge)
  manifest.loaf:5:1: [W002] services: the stack has no services
  manifest.loaf:7:3: [W010] artifact.path: OCI image 'registry.example.org/web:latest' is not pinned by digest (@sha256:…)
  manifest.loaf:11:3: [W011] health_check.timeout: timeout is not shorter than interval
  manifest.loaf:11:3: [W012] environment.DB_PASSWORD: looks like a literal secret: declare it in 'secrets'
  manifest.loaf:5:1: [W013] bundles: no bundles and no cloud_init_extra: nothing will happen at provision time
