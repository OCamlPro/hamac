Catalogue des erreurs du validateur (spécification du format de manifeste,
section « Validation ») : chaque code a un cas dans `cases/<code>-<sujet>/`.
Le validateur doit le refuser, avec `--strict` pour les avertissements, et le
diagnostic doit porter ce code. Pour chaque cas, on montre le diagnostic
attendu : la suite tient lieu de documentation des messages.

Un cas d'étage 1 est un manifeste seul ; un cas d'étage 2 ou 3 est une stack
et les manifestes qu'elle référence, validés ensemble.

  $ for d in cases/*/; do
  >   c=$(basename "$d"); code=${c%%-*}
  >   out=$(cd "$d" && hamac validate --strict *.yml 2>&1); rc=$?
  >   line=$(printf '%s\n' "$out" | grep -F "[$code]" | head -n 1 | sed 's/^hamac: \[[A-Z]*\] //')
  >   if [ "$rc" -ne 0 ] && [ -n "$line" ]; then echo "$line"; else echo "$c: NOT REFUSED"; printf '%s\n' "$out"; fi
  > done
  manifest.yml: (root): [E001] invalid YAML: error calling parser: did not find expected ',' or ']' character 0 position 0 returned: 0
  manifest.yml: manifest_version: [E002] manifest_version 2.0 is not supported (this hamac implements 1.1)
  manifest.yml: replica: [E003] unknown field 'replica' (expected one of: manifest_version, kind, name, metadata, runtime, artifact, capability, inputs, consumes, provides, readiness, security, ports, volumes, environment, resources, replicas, autoscaling, health_check, metrics, logging, storage, backup, secrets, placement, exposure)
  manifest.yml: name: [E004] 'Web_API' is not a DNS name (lowercase letters, digits and '-', starting with a letter, at most 63 characters)
  manifest.yml: kind: [E005] unknown manifest kind 'widget' (expected: service, pattern, stack, infrastructure, provisioning_profile, bundle)
  manifest.yml: runtime: [E006] required field 'runtime' is missing
  manifest.yml: replicas: [E007] expected an integer
  b.yml: name: [E010] service 'web' is already defined in a.yml
  manifest.yml: artifact.sha256: [E011] expected 64 hexadecimal characters (SHA-256)
  manifest.yml: consumes.1.name: [E012] duplicate consumes name 'db'
  manifest.yml: consumes.0: [E013] consumes 'db': exactly one of 'capability' and 'service'
  manifest.yml: resources.memory_request: [E014] request above its limit
  manifest.yml: resources.memory_limit: [E015] invalid quantity '1GB' (Ki, Mi, Gi or Ti)
  manifest.yml: autoscaling: [E016] expected 1 ≤ min_replicas ≤ max_replicas
  manifest.yml: environment.TOKEN: [E020] {secret.api_token} refers to no declared secret
  stack.yml: services.0.ref: [E021] 'absent.yml' not found (looked for ./absent.yml)
  stack.yml: services.0.consumes.0.name: [E022] service 'web' has no consumes entry named 'cache'
  web.yml: consumes.0: [E023] no provider of capability 'queue'
  manifest.yml: volumes: [E030] 'volumes' and 'storage' cannot be combined
  manifest.yml: storage.0.mount: [E031] mount 'data' is not an absolute path
  manifest.yml: storage.0.size: [E032] size is required for a persistent volume
  manifest.yml: storage.0: [E033] local volume 'data' has neither 'backup' nor 'rebuild': decide what happens to its data when the node is lost
  manifest.yml: secrets.0: [E034] secret 'key': exactly one of 'ref' and 'generate'
  manifest.yml: exposure.0.port: [E035] port 9090 is not declared in 'ports'
  portal.yml: consumes.0: [E040] portal (zone public) cannot consume vault (zone secure): opening a connection to a more sensitive zone is a read up, forbidden by the Bell-LaPadula model. If vault must expose data to zone public, have it push the declassified data to a service of that zone through a declared guard.
  high.yml: consumes.0: [E041] analyst (zone high) consumes sensor (zone low) across a diode: nothing can answer a request through it. Declare the flow 'mode: push', sensor sending what analyst receives.
  web.yml: security.zone: [E042] zone 'dmz' is not defined by the stack's patterns (zones: public, default, internal, secure)
  manifest.yml: security.route_labels.0: [E043] route '/health' is public: it cannot also require a classification, categories or roles
  web.yml: security.route_labels.0.classification: [E044] route '/vault' is classified secure, above zone internal (internal): a service holds no data more sensitive than its zone
  manifest.yml: proposed_topology.network.firewall.0: [E045] 'ALLOW public -> internal' opens a path without the declared flow that justifies it (expected: (consumer -> service))
  b.yml: lattice.levels: [E050] levels public < internal < secret differ from public < secret declared by another pattern of the stack
  b.yml: zones.0: [E051] zone 'rh' is already defined with another label or boundary
  manifest.yml: constraints.0.expr: [E052] count expects a set, got a host
  manifest.yml: placement: [W001] 'placement' is experimental: its meaning may change in a minor version (set accept_experimental: true in the stack to acknowledge)
  manifest.yml: ports.0.host: [W002] 'host' is deprecated: publish the port with 'exposure' (a host port pins the service to a machine)
  manifest.yml: artifact.path: [W010] OCI image 'registry.example.org/web:latest' is not pinned by digest (@sha256:…)
  manifest.yml: health_check.timeout: [W011] timeout is not shorter than interval
  manifest.yml: environment.DB_PASSWORD: [W012] looks like a literal secret: declare it in 'secrets'
  manifest.yml: bundles: [W013] no bundles and no cloud_init_extra: nothing will happen at provision time
