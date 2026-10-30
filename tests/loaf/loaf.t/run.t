Manifestes LOAF : les exemples du dépôt, convertis de YAML, sont lus par
`Loaf_source` (un ensemble de fichiers chargé d'un coup, avec le vocabulaire
de Hamac trouvé par dune-site). On les valide, puis on compare, manifeste par
manifeste, la valeur `Types` obtenue depuis LOAF à celle obtenue depuis le
YAML d'origine.

  $ R=../../..

Validation
==========

Une stack LOAF se charge avec ses services, son patron et les providers
qu'elle consomme : le langage refuse une référence à un bloc absent.

  $ hamac validate $R/examples/hr-stack/*.loaf $R/providers/*.loaf 2>&1 | sed "s|$R/||"
  examples/hr-stack/hr-api.loaf: service (name=hr-api, runtime=http)
  examples/hr-stack/payroll-report.loaf: service (name=payroll-report, runtime=batch)
  examples/hr-stack/portal.loaf: service (name=portal, runtime=http)
  providers/postgresql.loaf: service (name=postgresql, runtime=http)
  providers/redis.loaf: service (name=redis, runtime=http)
  examples/hr-stack/pattern.loaf: pattern (name=exemple-rh, version=1.0.0, 3 zones, 3 constraints)
  examples/hr-stack/stack.loaf: stack (name=hr, 3 services)
  hamac: [WARNING] providers/postgresql.loaf:25:3: [W010] artifact.path: OCI image 'postgres:15-alpine' is not pinned by digest (@sha256:…)
  hamac: [WARNING] providers/redis.loaf:19:3: [W010] artifact.path: OCI image 'redis:7-alpine' is not pinned by digest (@sha256:…)

  $ hamac validate $R/examples/enterprise-stack/*.loaf $R/providers/*.loaf 2>&1 | sed "s|$R/||"
  examples/enterprise-stack/analytics.loaf: service (name=analytics, runtime=eventloop)
  examples/enterprise-stack/payroll.loaf: service (name=payroll, runtime=http)
  providers/postgresql.loaf: service (name=postgresql, runtime=http)
  providers/redis.loaf: service (name=redis, runtime=http)
  examples/enterprise-stack/web_api.loaf: service (name=web-api, runtime=http)
  hamac: [WARNING] providers/postgresql.loaf:25:3: [W010] artifact.path: OCI image 'postgres:15-alpine' is not pinned by digest (@sha256:…)
  hamac: [WARNING] providers/redis.loaf:19:3: [W010] artifact.path: OCI image 'redis:7-alpine' is not pinned by digest (@sha256:…)

Un profil nomme ses bundles : il se charge avec eux.

  $ for p in $R/provisioning-profiles/*.loaf; do
  >   hamac validate $p $R/templates/bundles/dev-workstation/bundle.loaf 2>&1 | sed "s|$R/||"
  > done
  provisioning-profiles/dev-workstation-demo.loaf: provisioning_profile (name=dev-workstation-demo, os=debian-12-amd64-genericcloud, 1 bundles)
  templates/bundles/dev-workstation/bundle.loaf: bundle (name=dev-workstation, version=0.1.0, 6 params)
  provisioning-profiles/dev-workstation.loaf: provisioning_profile (name=dev-workstation, os=debian-12-amd64-genericcloud, 1 bundles)
  templates/bundles/dev-workstation/bundle.loaf: bundle (name=dev-workstation, version=0.1.0, 6 params)

Les diagnostics portent le fichier, la ligne et la colonne de l'élément en
faute. Leur code est celui de Hamac quand la validation vient du vocabulaire
(E016 ci-dessous) ou des contrôles de Hamac que le vocabulaire n'exprime pas
(E011, E014, E031, E033, W012…), celui du langage sinon (L002 : une valeur
hors de sa sorte, L007 : un champ obligatoire absent, L001 : une règle mal
formée, dont la lecture d'un attribut que rien ne définit), et E001 pour une
erreur de syntaxe.

  $ cat > faults.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.1.
  > 
  > service app {
  >   runtime http.
  >   replicas 0.
  >   storage data { mount "rel/path". class local. size 1, gi. }
  >   memory_request 2, gi.
  >   memory_limit 1, gi.
  >   environment "DB_PASSWORD", "hunter2".
  >   artifact "registry.example.org/app@sha256:x" { sha256 "zz". format oci_image. }
  > }
  > EOF
  $ hamac validate faults.loaf
  faults.loaf: service (name=app, runtime=http)
  hamac: [ERROR] faults.loaf:6:3: [E016] replicas must be at least 1
  hamac: [ERROR] faults.loaf:11:3: [E011] artifact.sha256: expected 64 hexadecimal characters (SHA-256)
  hamac: [ERROR] faults.loaf:8:3: [E014] resources.memory_request: request above its limit
  hamac: [ERROR] faults.loaf:7:18: [E031] storage.0.mount: mount 'rel/path' is not an absolute path
  hamac: [ERROR] faults.loaf:7:3: [E033] storage.0: local volume 'data' has neither 'backup' nor 'rebuild': decide what happens to its data when the node is lost
  hamac: [WARNING] faults.loaf:7:3: [W001] storage: 'storage' is experimental: its meaning may change in a minor version (write accept_experimental in the stack to acknowledge)
  hamac: [WARNING] faults.loaf:10:3: [W012] environment.DB_PASSWORD: looks like a literal secret: declare it in 'secrets'
  [1]
  $ cat > refusals.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.1.
  > service app { runtime http. affinity nobody. }
  > EOF
  $ hamac validate refusals.loaf
  hamac: [ERROR] refusals.loaf:3:29: [L002] service.affinity(app, nobody): nobody does not belong to sort service
  [1]
  $ printf 'loaf 0.1.\nuse hamac 0.1.\nservice app { replicas 2. }\n' > missing.loaf
  $ hamac validate missing.loaf
  hamac: [ERROR] missing.loaf:3:1: [L007] service(app): field runtime has no value
  [1]
  $ printf 'loaf 0.1.\nuse hamac 0.1.\nservice app { runtime http }\n' > syntax.loaf
  $ hamac validate syntax.loaf
  hamac: [ERROR] syntax.loaf:3:28: [E001] syntax error before '}'; expected, among others: '.' ending an instruction, ':-', ',' or ';'
  [1]

Un gabarit lit, par la consommation, le provider retenu vu comme le contrat
de la capacité consommée (`{~.database.user}`), ou le point d'accès d'un
service consommé (`{~.host}`, `{~.port}`). Chaque maillon est vérifié contre
la déclaration de son bloc : un attribut mal orthographié, un attribut du bloc
`service` du provider, ou un attribut que la consommation n'a pas, sont
refusés.

  $ for t in '~.database.usr' '~.database.runtime' '~.runtime' '~.user'; do
  >   printf 'loaf 0.1.\nuse hamac 0.1.\nservice app {\n  runtime http.\n  consumes db {\n    capability database.\n    inject "URL", fmt("{%s}").\n  }\n}\n' "$t" > typo.loaf
  >   echo "{$t}"; hamac validate typo.loaf $R/providers/*.loaf 2>&1 | sed "s|$R/||"
  > done
  {~.database.usr}
  hamac: [ERROR] typo.loaf:7:5: [L001] database.usr: block database has no attribute usr
  {~.database.runtime}
  hamac: [ERROR] typo.loaf:7:5: [L001] database.runtime: block database has no attribute runtime
  {~.runtime}
  hamac: [ERROR] typo.loaf:7:5: [L001] attribute runtime is not defined for a block with 2 subject(s): no field declares it, no rule defines it
  {~.user}
  hamac: [ERROR] typo.loaf:7:5: [L001] attribute user is not defined for a block with 2 subject(s): no field declares it, no rule defines it

Un provider remplit le contrat de sa capacité, et un contrat n'est rempli que
par un provider de cette capacité (E024).

  $ cat > contract.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.1.
  > service memo { runtime http. capability cache. }
  > service other { runtime http. }
  > database other { host "db". port 5432. user "u". password "p". dbname "d". }
  > EOF
  $ hamac validate contract.loaf
  contract.loaf: service (name=memo, runtime=http)
  contract.loaf: service (name=other, runtime=http)
  hamac: [ERROR] contract.loaf:3:30: [E024] memo provides the capability cache without a cache block
  hamac: [ERROR] contract.loaf:5:1: [E024] database block of other, which is not a service providing database
  [1]

Comparaison avec les YAML d'origine
===================================

`compare.exe` apparie les manifestes par sorte et par nom, écrit leurs deux
valeurs `Types` et les liste ; `d` affiche l'écart d'une paire. Les listes qui
sont des ensembles en LOAF sont triées des deux côtés (LOAF les donne dans
l'ordre des termes, YAML dans l'ordre d'écriture) : cet écart-là n'est pas
montré.

  $ d () { diff -u --label yaml --label loaf $1.yaml $1.loaf; }

Exemple hr-stack
----------------

  $ ../compare.exe hr $R/examples/hr-stack/*.yml $R/providers/*.yml $R/examples/hr-stack/*.loaf $R/providers/*.loaf
  pattern-exemple-rh
  service-hr-api
  service-payroll-report
  service-portal
  service-postgresql
  service-redis
  stack-hr

Patron : un identifiant de contrainte est une constante LOAF, qui ne peut
pas porter de `-` ; la convention `_` → `-` ne vaut que pour les noms de
manifestes, l'identifiant reste donc `one_level_per_host`. Le texte d'une
contrainte écrite sur plusieurs lignes en YAML (bloc `>`) est d'une ligne en
LOAF : l'expression analysée (`expr`) est la même.

  $ d hr/pattern-exemple-rh
  --- yaml
  +++ loaf
  @@ -13,7 +13,7 @@
        pat_assurance =
        [("rh", { Types.boot = (Some "measured-tpm2"); operator = None; physical = (Some "site") })];
        constraints =
  -     [{ Types.cid = "one-level-per-host";
  +     [{ Types.cid = "one_level_per_host";
           cdescription = "Deux niveaux ne partagent jamais un noyau"; severity = "hard";
           weight = None; expr_src = "forall h in hosts: count(levels_on(h)) <= 1";
           expr =
  @@ -25,10 +25,10 @@
                 (Constraint_lang.Int 1)))
              ))
           };
  -       { Types.cid = "rh-on-site"; cdescription = "Les donn\195\169es RH restent sur le site";
  +       { Types.cid = "rh_on_site"; cdescription = "Les donn\195\169es RH restent sur le site";
            severity = "hard"; weight = None;
            expr_src =
  -         "forall s in services where zone(s) = \"rh\":\n  forall h in hosts_of(s): h.physical = \"site\"\n";
  +         "forall s in services where zone(s) = \"rh\": forall h in hosts_of(s): h.physical = \"site\"";
            expr =
            (Constraint_lang.Quant (Constraint_lang.Forall, "s", (Constraint_lang.Domain "services"),
               (Some (Constraint_lang.Cmp (Constraint_lang.Eq,
  @@ -41,12 +41,12 @@
                  ))
               ))
            };
  -       { Types.cid = "stateful-quorum";
  +       { Types.cid = "stateful_quorum";
            cdescription =
            "Un service \195\160 \195\169tat survit \195\160 la perte d'un domaine de panne";
            severity = "hard"; weight = None;
            expr_src =
  -         "forall s in services where stateful(s):\n  count(failure_domains(hosts_of(s))) >= 3\n";
  +         "forall s in services where stateful(s): count(failure_domains(hosts_of(s))) >= 3";
            expr =
            (Constraint_lang.Quant (Constraint_lang.Forall, "s", (Constraint_lang.Domain "services"),
               (Some (Constraint_lang.Term
  [1]

Service consommateur d'une capacité : le modèle remplit le gabarit
`fmt("…{~.user}…")` avec les attributs du provider qu'il a retenu ; le
gabarit arrive donc exprimé dans les termes de l'instance du provider
(`input(user)` → `{input.user}`, `instance(name)` → `{service_name}`, le port
offert `5432` en clair), que le résolveur substitue, au lieu des clés de ses
`provides` (`{user}`). Le résultat résolu est le même (voir plus bas).

  $ d hr/service-hr-api
  --- yaml
  +++ loaf
  @@ -8,7 +8,9 @@
        capability = None; inputs = [];
        consumes =
        [{ Types.name = "db"; capability = (Some "database"); service = None;
  -        inject = [("DATABASE_URL", "postgresql://{user}:{password}@{host}:{port}/{dbname}")];
  +        inject =
  +        [("DATABASE_URL",
  +          "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
           mode = "request" }
          ];
        provides = []; readiness = None;
  [1]

Consommation d'un service : `{~.host}` est `host(hr_api)`, rendu `{host}`
que le résolveur substitue par le point d'accès du service ; `{~.port}` est le
premier port déclaré, que le modèle donne en clair.

  $ d hr/service-payroll-report
  --- yaml
  +++ loaf
  @@ -8,7 +8,7 @@
        capability = None; inputs = [];
        consumes =
        [{ Types.name = "api"; capability = None; service = (Some "hr-api");
  -        inject = [("HR_API_URL", "http://{host}:{port}")]; mode = "request" }
  +        inject = [("HR_API_URL", "http://{host}:8080")]; mode = "request" }
          ];
        provides = []; readiness = None; security = (Some { Types.zone = "rh"; route_labels = [] });
        ports = []; volumes = []; environment = [];
  [1]

La quantité CPU est écrite `500, m` dans l'exemple LOAF : `500m`, la même
que `0.5` en YAML.

  $ d hr/service-portal
  --- yaml
  +++ loaf
  @@ -11,7 +11,7 @@
        volumes = []; environment = [];
        resources =
        (Some { Types.memory_limit = (Some "256Mi"); memory_request = None; 
  -             cpu_limit = (Some "0.5"); cpu_request = None });
  +             cpu_limit = (Some "500m"); cpu_request = None });
        replicas = 2; autoscaling = None;
        health_check = (Some { Types.path = "/health"; interval = 10; timeout = 3; retries = 3 });
        metrics = None; logging = None;
  [1]

Provider : ses `provides` viennent du contrat de sa capacité (`database
postgresql { … }`) et sont ceux du YAML. Le YAML est au format 1.0, le
vocabulaire implémente le 1.1 (`manifest_version` d'un manifeste LOAF) ;
`port.host`, déprécié en 1.1, n'est plus dans le vocabulaire.

  $ d hr/service-postgresql
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MService
  -   { Types.manifest_version = "1.0"; name = "postgresql"; runtime = "http";
  +   { Types.manifest_version = "1.1"; name = "postgresql"; runtime = "http";
        artifact =
        (Some { Types.path = "postgres:15-alpine";
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  @@ -15,7 +15,7 @@
        readiness =
        (Some { Types.command = ["pg_isready"; "-U"; "{input.user}"]; readiness_interval = 5;
                readiness_timeout = 30 });
  -     security = None; ports = [{ Types.host = (Some 5432); container = 5432; protocol = "tcp" }];
  +     security = None; ports = [{ Types.host = None; container = 5432; protocol = "tcp" }];
        volumes = [];
        environment =
        [("POSTGRES_DB", "{input.dbname}"); ("POSTGRES_PASSWORD", "{input.password}");
  [1]

Même écart pour redis.

  $ d hr/service-redis
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MService
  -   { Types.manifest_version = "1.0"; name = "redis"; runtime = "http";
  +   { Types.manifest_version = "1.1"; name = "redis"; runtime = "http";
        artifact =
        (Some { Types.path = "redis:7-alpine";
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  @@ -10,7 +10,7 @@
        readiness =
        (Some { Types.command = ["redis-cli"; "-a"; "{input.password}"; "ping"];
                readiness_interval = 5; readiness_timeout = 30 });
  -     security = None; ports = [{ Types.host = (Some 6379); container = 6379; protocol = "tcp" }];
  +     security = None; ports = [{ Types.host = None; container = 6379; protocol = "tcp" }];
        volumes = []; environment = [("REDIS_PASSWORD", "{input.password}")]; 
        resources = None; replicas = 1; autoscaling = None; health_check = None; 
        metrics = None; logging = None;
  [1]

Une stack LOAF nomme ses services : `ref_path` est le nom du service, et non
plus le chemin de son fichier.

  $ d hr/stack-hr
  --- yaml
  +++ loaf
  @@ -2,7 +2,7 @@
      { Types.manifest_version = "1.1"; name = "hr"; patterns = ["exemple-rh"];
        accept_experimental = true;
        services =
  -     [{ Types.ref_path = "hr-api.yml"; replicas_override = None; consumes_override = [] };
  -       { Types.ref_path = "payroll-report.yml"; replicas_override = None; consumes_override = [] };
  -       { Types.ref_path = "portal.yml"; replicas_override = None; consumes_override = [] }];
  +     [{ Types.ref_path = "hr-api"; replicas_override = None; consumes_override = [] };
  +       { Types.ref_path = "payroll-report"; replicas_override = None; consumes_override = [] };
  +       { Types.ref_path = "portal"; replicas_override = None; consumes_override = [] }];
        infrastructure = None })
  [1]

Exemple enterprise-stack
------------------------

  $ ../compare.exe ent $R/examples/enterprise-stack/*.yml $R/providers/*.yml $R/examples/enterprise-stack/*.loaf $R/providers/*.loaf
  service-analytics
  service-payroll
  service-postgresql
  service-redis
  service-web-api

Les mêmes écarts : version 1.0, gabarits remplis par le modèle, et la
référence `web_api`, nom 1.0 avec `_`, devenue `web-api`.

  $ d ent/service-analytics
  --- yaml
  +++ loaf
  @@ -1,18 +1,20 @@
   (Types.MService
  -   { Types.manifest_version = "1.0"; name = "analytics"; runtime = "eventloop";
  +   { Types.manifest_version = "1.1"; name = "analytics"; runtime = "eventloop";
        artifact =
        (Some { Types.path = "./bin/analytics";
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
                format = "native-linux-amd64" });
        capability = None; inputs = [];
        consumes =
  -     [{ Types.name = "api"; capability = None; service = (Some "web_api");
  -        inject = [("API_URL", "http://{host}:{port}")]; mode = "request" };
  +     [{ Types.name = "api"; capability = None; service = (Some "web-api");
  +        inject = [("API_URL", "http://{host}:8080")]; mode = "request" };
          { Types.name = "cache"; capability = (Some "cache"); service = None;
  -         inject = [("REDIS_URL", "redis://:{password}@{host}:{port}")]; 
  +         inject = [("REDIS_URL", "redis://:{input.password}@{service_name}:6379")];
            mode = "request" };
          { Types.name = "db"; capability = (Some "database"); service = None;
  -         inject = [("DATABASE_URL", "postgresql://{user}:{password}@{host}:{port}/{dbname}")];
  +         inject =
  +         [("DATABASE_URL",
  +           "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
            mode = "request" }
          ];
        provides = []; readiness = None;
  [1]

Version, gabarit, et la quantité CPU `500, m`.

  $ d ent/service-payroll
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MService
  -   { Types.manifest_version = "1.0"; name = "payroll"; runtime = "http";
  +   { Types.manifest_version = "1.1"; name = "payroll"; runtime = "http";
        artifact =
        (Some { Types.path = "./bin/payroll";
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  @@ -7,7 +7,9 @@
        capability = None; inputs = [];
        consumes =
        [{ Types.name = "db"; capability = (Some "database"); service = None;
  -        inject = [("DATABASE_URL", "postgresql://{user}:{password}@{host}:{port}/{dbname}")];
  +        inject =
  +        [("DATABASE_URL",
  +          "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
           mode = "request" }
          ];
        provides = []; readiness = None;
  @@ -24,7 +26,7 @@
        ports = []; volumes = []; environment = [];
        resources =
        (Some { Types.memory_limit = (Some "256Mi"); memory_request = None; 
  -             cpu_limit = (Some "0.5"); cpu_request = None });
  +             cpu_limit = (Some "500m"); cpu_request = None });
        replicas = 2; autoscaling = None; health_check = None; metrics = None; 
        logging = None; metadata = { Types.description = None; labels = []; annotations = [] };
        storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  [1]

Version, nom `web_api` → `web-api`, gabarit, port sans `host`.

  $ d ent/service-web-api
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MService
  -   { Types.manifest_version = "1.0"; name = "web_api"; runtime = "http";
  +   { Types.manifest_version = "1.1"; name = "web-api"; runtime = "http";
        artifact =
        (Some { Types.path = "./bin/web_api";
                sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
  @@ -7,12 +7,14 @@
        capability = None; inputs = [];
        consumes =
        [{ Types.name = "db"; capability = (Some "database"); service = None;
  -        inject = [("DATABASE_URL", "postgresql://{user}:{password}@{host}:{port}/{dbname}")];
  +        inject =
  +        [("DATABASE_URL",
  +          "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
           mode = "request" }
          ];
        provides = []; readiness = None;
        security = (Some { Types.zone = "public"; route_labels = [] });
  -     ports = [{ Types.host = (Some 8080); container = 8080; protocol = "tcp" }]; 
  +     ports = [{ Types.host = None; container = 8080; protocol = "tcp" }]; 
        volumes = []; environment = [];
        resources =
        (Some { Types.memory_limit = (Some "512Mi"); memory_request = None; 
  [1]

Profils et bundle
-----------------

  $ ../compare.exe pp $R/provisioning-profiles/*.yaml $R/templates/bundles/dev-workstation/bundle.yaml $R/provisioning-profiles/*.loaf $R/templates/bundles/dev-workstation/bundle.loaf
  bundle-dev-workstation
  provisioning_profile-dev-workstation
  provisioning_profile-dev-workstation-demo

Bundle et profils : seule la version du format diffère.

  $ d pp/bundle-dev-workstation
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MBundle
  -   { Types.bdl_manifest_version = "1.0"; bdl_name = "dev-workstation"; 
  +   { Types.bdl_manifest_version = "1.1"; bdl_name = "dev-workstation"; 
        bdl_version = "0.1.0";
        bdl_description = "Poste de dev minimal : utilisateur sudo, SSH, docker, dotfiles optionnels";
        bdl_params =
  [1]

  $ d pp/provisioning_profile-dev-workstation
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MProvisioningProfile
  -   { Types.pp_manifest_version = "1.0"; pp_name = "dev-workstation";
  +   { Types.pp_manifest_version = "1.1"; pp_name = "dev-workstation";
        pp_os =
        { Types.os_image_name = "debian-12-amd64-genericcloud";
          os_url =
  [1]

  $ d pp/provisioning_profile-dev-workstation-demo
  --- yaml
  +++ loaf
  @@ -1,5 +1,5 @@
   (Types.MProvisioningProfile
  -   { Types.pp_manifest_version = "1.0"; pp_name = "dev-workstation-demo";
  +   { Types.pp_manifest_version = "1.1"; pp_name = "dev-workstation-demo";
        pp_os =
        { Types.os_image_name = "debian-12-amd64-genericcloud";
          os_url =
  [1]

Ordre des bundles
=================

Les cloud-init des bundles d'un profil sont fusionnés dans l'ordre de sa
liste `bundles`, le suivant l'emportant sur une valeur scalaire. Les
paramètres d'un bundle que la liste ne nomme pas sont refusés (E007).

  $ for b in first second; do
  >   mkdir -p bundles/$b
  >   printf 'loaf 0.1.\nuse hamac 0.1.\nbundle %s {}\n' $b > bundles/$b/bundle.loaf
  >   printf 'timezone: %s\n' $b > bundles/$b/cloud-init.yaml.j2
  > done
  $ profile () {
  >   printf 'loaf 0.1.\nuse hamac 0.1.\nprovisioning_profile p {\n  os "img" { url "http://x/img.qcow2". sha256 "%s". format qcow2. }\n  %s\n}\n' \
  >     0000000000000000000000000000000000000000000000000000000000000000 "$1" > p.loaf
  >   hamac provision-dryrun --profile=p.loaf --bundles-dir=bundles 2>&1 | grep -E '^timezone|ERROR'
  > }
  $ profile 'bundles [first, second].'
  timezone: second
  $ profile 'bundles [second, first].'
  timezone: first
  $ profile 'bundles [first]. bundle second { param x { value "y". } }'
  hamac: [ERROR] p.loaf:5:20: [E007] parameters of the bundle second, which bundles does not list

Effet sur les commandes
=======================

Le résolveur substitue dans le gabarit déjà rempli les termes de l'instance
du provider : les injections résolues ont la forme de celles du YAML.

  $ hamac resolve --seed 42 $R/examples/hr-stack/*.loaf $R/providers/*.loaf 2>/dev/null | sed -n '/^Wiring/,$p'
  Wiring:
    hr-api.db -> postgresql
      inject: DATABASE_URL=postgresql://pottxvuimhan:z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs@postgresql-hr-api-db:5432/hr-api_db
    payroll-report.api -> hr-api (service)
      inject: HR_API_URL=http://hr-api:8080

Le plan d'une stack LOAF ne compte pas les providers comme des services : il
est celui du YAML. Le rendu d'un profil LOAF est aussi celui du YAML.

  $ (cd $R && hamac plan examples/hr-stack/*.yml) > plan-yaml.txt 2>&1
  $ (cd $R && hamac plan examples/hr-stack/*.loaf providers/*.loaf) > plan-loaf.txt 2>&1
  $ diff plan-yaml.txt plan-loaf.txt
  $ hamac provision-dryrun --profile=$R/provisioning-profiles/dev-workstation-demo.yaml --bundles-dir=$R/templates/bundles > dry-yaml.txt 2>&1
  $ hamac provision-dryrun --profile=$R/provisioning-profiles/dev-workstation-demo.loaf --bundles-dir=$R/templates/bundles > dry-loaf.txt 2>&1
  $ diff dry-yaml.txt dry-loaf.txt
