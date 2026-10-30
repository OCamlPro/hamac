Manifestes LOAF : les exemples du dépôt sont lus par `Loaf_source` (un
ensemble de fichiers chargé d'un coup, avec le vocabulaire de Hamac trouvé
par dune-site, et les patrons, modules, cherchés dans les répertoires de
bibliothèque). On les valide, on fige les valeurs `Types` que le chargeur en
construit, puis les sorties des commandes.

  $ R=../../..

Validation
==========

Une stack se charge avec ses services et les providers qu'elle consomme ; un
dossier vaut les `.loaf` qu'il contient. Son patron est un module, qu'elle
charge par `use` : parmi les fichiers donnés (le dossier de l'exemple contient
`patterns/`), ou depuis un répertoire de bibliothèque (`./patterns` par
défaut, ou `-L`). Le langage refuse une référence à un bloc absent, ou un
module introuvable : ici, les fichiers de la stack sans son patron.

  $ hamac validate $R/examples/hr-stack/*.loaf $R/providers 2>&1 | sed "s|$R/||"
  hamac: [ERROR] examples/hr-stack/stack.loaf:15:1: [L009] use exemple_rh: no available version satisfies 1.0 (available: none)

  $ (cd $R && hamac validate examples/hr-stack providers)
  examples/hr-stack/hr-api.loaf: service (name=hr-api, runtime=http)
  examples/hr-stack/payroll-report.loaf: service (name=payroll-report, runtime=batch)
  examples/hr-stack/portal.loaf: service (name=portal, runtime=http)
  providers/postgresql.loaf: service (name=postgresql, runtime=http)
  providers/redis.loaf: service (name=redis, runtime=http)
  examples/hr-stack/patterns/exemple_rh.loaf: pattern (name=exemple-rh, version=1.0.0, 3 zones, 2 constraints)
  examples/hr-stack/stack.loaf: stack (name=hr, 3 services)

  $ hamac validate $R/examples/enterprise-stack $R/providers 2>&1 | sed "s|$R/||"
  examples/enterprise-stack/analytics.loaf: service (name=analytics, runtime=eventloop)
  examples/enterprise-stack/payroll.loaf: service (name=payroll, runtime=http)
  providers/postgresql.loaf: service (name=postgresql, runtime=http)
  providers/redis.loaf: service (name=redis, runtime=http)
  examples/enterprise-stack/web_api.loaf: service (name=web-api, runtime=http)
  examples/enterprise-stack/organisation.loaf: pattern (name=organisation, 0 zones, 0 constraints)

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
  > use hamac 0.2.
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
  hamac: [ERROR] faults.loaf:11:3: [E011] sha256 of the artifact of app: expected 64 hexadecimal characters
  hamac: [ERROR] faults.loaf:8:3: [E014] memory_request of app above its memory_limit
  hamac: [ERROR] faults.loaf:7:18: [E031] mount 'rel/path' of volume data is not an absolute path
  hamac: [ERROR] faults.loaf:7:3: [E033] local volume 'data' has neither 'backup' nor 'rebuild': decide what happens to its data when the node is lost
  hamac: [WARNING] faults.loaf:7:3: [W001] 'storage' is experimental: its meaning may change in a minor version (write accept_experimental in the stack to acknowledge)
  hamac: [WARNING] faults.loaf:10:3: [W012] environment DB_PASSWORD of app looks like a literal secret: declare it as a secret
  [1]
  $ cat > refusals.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.2.
  > service app { runtime http. affinity nobody. }
  > EOF
  $ hamac validate refusals.loaf
  hamac: [ERROR] refusals.loaf:3:29: [L002] service.affinity(app, nobody): nobody does not belong to sort service
  [1]
  $ printf 'loaf 0.1.\nuse hamac 0.2.\nservice app { replicas 2. }\n' > missing.loaf
  $ hamac validate missing.loaf
  hamac: [ERROR] missing.loaf:3:1: [L007] service(app): field runtime has no value
  [1]
  $ printf 'loaf 0.1.\nuse hamac 0.2.\nservice app { runtime http }\n' > syntax.loaf
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
  >   printf 'loaf 0.1.\nuse hamac 0.2.\nservice app {\n  runtime http.\n  consumes db {\n    capability database.\n    inject "URL", fmt("{%s}").\n  }\n}\n' "$t" > typo.loaf
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
  > use hamac 0.2.
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

Valeurs construites
===================

`show.exe` affiche les valeurs `Types` qu'un ensemble de fichiers donne : ce
que le reste de Hamac reçoit du chargeur. Les gabarits y sont dans le
mini-langage `{…}` que le résolveur substitue : un `inject` arrive rempli par
le modèle avec les termes de l'instance du provider (`{input.user}`,
`{service_name}`), le point d'accès d'un service consommé est `{host}` et son
premier port.

  $ ../show.exe -L $R/patterns $R/examples/hr-stack $R/providers | sed "s|$R/||"
  == examples/hr-stack/hr-api.loaf
  (Types.MService
     { Types.name = "hr-api"; runtime = "http";
       artifact =
       (Some { Types.path =
               "registry.example.org/rh/hr-api@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               format = "oci-image" });
       capability = None; inputs = [];
       consumes =
       [{ Types.name = "db"; capability = (Some "database"); service = None;
          provider = (Some "postgresql");
          inject =
          [("DATABASE_URL",
            "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
          mode = "request" }
         ];
       provides = []; readiness = None;
       security =
       (Some { Types.zone = "rh";
               route_labels =
               [{ Types.route = "/employees/*"; methods = ["GET"]; public = false;
                  classification = (Some "internal"); categories = ["rh"];
                  required_clearance = ["admin"; "rh"] };
                 { Types.route = "/employees/salaries"; methods = []; public = false;
                   classification = (Some "confidential"); categories = ["finance"; "rh"];
                   required_clearance = ["admin"; "comptable"] };
                 { Types.route = "/health"; methods = []; public = true; 
                   classification = None; categories = []; required_clearance = [] }
                 ]
               });
       ports = [{ Types.container = 8080; protocol = "tcp" }];
       environment = [("SESSION_KEY", "{secret.session_key}")];
       resources =
       (Some { Types.memory_limit = (Some "512Mi"); memory_request = (Some "256Mi");
               cpu_limit = (Some "1"); cpu_request = None });
       replicas = 2; autoscaling = None;
       health_check = (Some { Types.path = "/health"; interval = 10; timeout = 3; retries = 3 });
       metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None;
       secrets =
       [{ Types.sec_name = "session_key"; sec_ref = None;
          generate = (Some { Types.gen_kind = "alnum"; gen_length = 64 }); 
          rotate = (Some "90d"); sec_as = "env" }
         ];
       placement =
       (Some { Types.needs = []; pl_assurance = None; spread = "failure_domain"; 
               affinity = []; anti_affinity = [] });
       exposure =
       [{ Types.hostname = "api.rh.example.org"; path_prefix = "/"; exp_port = 8080;
          exp_protocol = "http"; tls = "acme" }
         ]
       })
  == examples/hr-stack/payroll-report.loaf
  (Types.MService
     { Types.name = "payroll-report"; runtime = "batch";
       artifact =
       (Some { Types.path =
               "registry.example.org/rh/payroll-report@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               format = "oci-image" });
       capability = None; inputs = [];
       consumes =
       [{ Types.name = "api"; capability = None; service = (Some "hr-api");
          provider = (Some "hr-api"); inject = [("HR_API_URL", "http://{host}:8080")];
          mode = "request" }
         ];
       provides = []; readiness = None; security = (Some { Types.zone = "rh"; route_labels = [] });
       ports = []; environment = [];
       resources =
       (Some { Types.memory_limit = (Some "1Gi"); memory_request = None; 
               cpu_limit = (Some "2"); cpu_request = None });
       replicas = 1; autoscaling = None; health_check = None; metrics = None; 
       logging = None; metadata = { Types.description = None; labels = []; annotations = [] };
       storage =
       [{ Types.st_name = "cache"; mount = "/var/cache/report"; st_class = "local";
          size = (Some "5Gi"); rebuild = (Some "none") };
         { Types.st_name = "scratch"; mount = "/tmp/work"; st_class = "ephemeral"; 
           size = None; rebuild = None }
         ];
       backup = None; secrets = []; placement = None; exposure = [] })
  == examples/hr-stack/portal.loaf
  (Types.MService
     { Types.name = "portal"; runtime = "http";
       artifact =
       (Some { Types.path =
               "registry.example.org/rh/portal@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
               format = "oci-image" });
       capability = None; inputs = []; consumes = []; provides = []; readiness = None;
       security = (Some { Types.zone = "public"; route_labels = [] });
       ports = [{ Types.container = 8080; protocol = "tcp" }]; environment = [];
       resources =
       (Some { Types.memory_limit = (Some "256Mi"); memory_request = None; 
               cpu_limit = (Some "500m"); cpu_request = None });
       replicas = 2; autoscaling = None;
       health_check = (Some { Types.path = "/health"; interval = 10; timeout = 3; retries = 3 });
       metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None; secrets = []; placement = None;
       exposure =
       [{ Types.hostname = "rh.example.org"; path_prefix = "/"; exp_port = 8080;
          exp_protocol = "http"; tls = "acme" }
         ]
       })
  == providers/postgresql.loaf
  (Types.MService
     { Types.name = "postgresql"; runtime = "http";
       artifact =
       (Some { Types.path =
               "postgres:15-alpine@sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984";
               sha256 = "54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984";
               format = "oci-image" });
       capability = (Some "database");
       inputs =
       [("dbname", "{consumer.name}_db"); ("password", "{generate.alnum(32)}");
         ("user", "{generate.alpha(12)}")];
       consumes = [];
       provides =
       [("dbname", "{input.dbname}"); ("host", "{service_name}"); ("password", "{input.password}");
         ("port", "5432"); ("user", "{input.user}")];
       readiness =
       (Some { Types.command = ["pg_isready"; "-U"; "{input.user}"]; readiness_interval = 5;
               readiness_timeout = 30 });
       security = None; ports = [{ Types.container = 5432; protocol = "tcp" }];
       environment =
       [("POSTGRES_DB", "{input.dbname}"); ("POSTGRES_PASSWORD", "{input.password}");
         ("POSTGRES_USER", "{input.user}")];
       resources = None; replicas = 1; autoscaling = None; health_check = None; 
       metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == providers/redis.loaf
  (Types.MService
     { Types.name = "redis"; runtime = "http";
       artifact =
       (Some { Types.path =
               "redis:7-alpine@sha256:8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f";
               sha256 = "8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f";
               format = "oci-image" });
       capability = (Some "cache"); inputs = [("password", "{generate.alnum(32)}")]; 
       consumes = [];
       provides = [("host", "{service_name}"); ("password", "{input.password}"); ("port", "6379")];
       readiness =
       (Some { Types.command = ["redis-cli"; "-a"; "{input.password}"; "ping"];
               readiness_interval = 5; readiness_timeout = 30 });
       security = None; ports = [{ Types.container = 6379; protocol = "tcp" }];
       environment = [("REDIS_PASSWORD", "{input.password}")]; resources = None; 
       replicas = 1; autoscaling = None; health_check = None; metrics = None; 
       logging = None; metadata = { Types.description = None; labels = []; annotations = [] };
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == examples/hr-stack/patterns/exemple_rh.loaf
  (Types.MPattern
     { Types.pat_name = "exemple-rh"; pat_version = (Some "1.0.0");
       lattice =
       (Some { Types.levels = ["public"; "internal"; "confidential"];
               lat_categories = ["finance"; "rh"] });
       zones =
       [{ Types.zname = "internal"; zlevel = "internal"; zcategories = []; boundary = "firewall" };
         { Types.zname = "public"; zlevel = "public"; zcategories = []; boundary = "firewall" };
         { Types.zname = "rh"; zlevel = "confidential"; zcategories = ["finance"; "rh"];
           boundary = "firewall" }
         ];
       pat_assurance =
       [("rh", { Types.boot = (Some "measured-tpm2"); operator = None; physical = (Some "site") })];
       pat_roles = ["admin"; "comptable"; "rh"];
       constraints =
       [{ Types.cid = "one_level_per_host";
          cdescription = "Deux niveaux ne partagent jamais un noyau"; severity = "hard"; 
          weight = 1; cpriority = 1; violation = "H : level_on(H, L1), level_on(H, L2), L1 != L2";
          cloc =
          (Some { Diagnostic.file = "examples/hr-stack/patterns/exemple_rh.loaf"; 
                  line = 31; column = 5 })
          };
         { Types.cid = "stateful_quorum";
           cdescription =
           "Un service \195\160 \195\169tat survit \195\160 la perte d'un domaine de panne";
           severity = "soft"; weight = 1; cpriority = 1;
           violation = "S : stateful(S), #count { D : on(S, H), failure_domain(H, D) } < 3";
           cloc =
           (Some { Diagnostic.file = "examples/hr-stack/patterns/exemple_rh.loaf";
                   line = 37; column = 5 })
           }
         ];
       objectives =
       [{ Types.direction = "minimize"; element = "1, H : used(H)"; priority = 1;
          oloc =
          (Some { Diagnostic.file = "examples/hr-stack/patterns/exemple_rh.loaf"; 
                  line = 40; column = 3 })
          }
         ]
       })
  == examples/hr-stack/stack.loaf
  (Types.MStack
     { Types.name = "hr"; accept_experimental = true;
       services =
       [{ Types.ref_service = "hr-api"; replicas_override = None; consumes_override = [] };
         { Types.ref_service = "payroll-report"; replicas_override = None; consumes_override = [] };
         { Types.ref_service = "portal"; replicas_override = None; consumes_override = [] }];
       infrastructure = None })

  $ ../show.exe $R/examples/enterprise-stack $R/providers | sed "s|$R/||"
  == examples/enterprise-stack/analytics.loaf
  (Types.MService
     { Types.name = "analytics"; runtime = "eventloop";
       artifact =
       (Some { Types.path = "./bin/analytics";
               sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
               format = "native-linux-amd64" });
       capability = None; inputs = [];
       consumes =
       [{ Types.name = "api"; capability = None; service = (Some "web-api");
          provider = (Some "web-api"); inject = [("API_URL", "http://{host}:8080")]; 
          mode = "request" };
         { Types.name = "cache"; capability = (Some "cache"); service = None;
           provider = (Some "redis");
           inject = [("REDIS_URL", "redis://:{input.password}@{service_name}:6379")];
           mode = "request" };
         { Types.name = "db"; capability = (Some "database"); service = None;
           provider = (Some "postgresql");
           inject =
           [("DATABASE_URL",
             "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
           mode = "request" }
         ];
       provides = []; readiness = None;
       security = (Some { Types.zone = "internal"; route_labels = [] }); 
       ports = []; environment = [];
       resources =
       (Some { Types.memory_limit = (Some "1Gi"); memory_request = None; 
               cpu_limit = (Some "2"); cpu_request = None });
       replicas = 2;
       autoscaling =
       (Some { Types.min_replicas = 2; max_replicas = 8; cpu_threshold = (Some 60);
               memory_threshold = None });
       health_check = None; metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == examples/enterprise-stack/payroll.loaf
  (Types.MService
     { Types.name = "payroll"; runtime = "http";
       artifact =
       (Some { Types.path = "./bin/payroll";
               sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
               format = "native-linux-amd64" });
       capability = None; inputs = [];
       consumes =
       [{ Types.name = "db"; capability = (Some "database"); service = None;
          provider = (Some "postgresql");
          inject =
          [("DATABASE_URL",
            "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
          mode = "request" }
         ];
       provides = []; readiness = None;
       security =
       (Some { Types.zone = "secure";
               route_labels =
               [{ Types.route = "/employees/*"; methods = []; public = false; 
                  classification = None; categories = []; required_clearance = ["admin"] };
                 { Types.route = "/salary/*"; methods = []; public = false; 
                   classification = None; categories = [];
                   required_clearance = ["admin"; "comptable"] }
                 ]
               });
       ports = []; environment = [];
       resources =
       (Some { Types.memory_limit = (Some "256Mi"); memory_request = None; 
               cpu_limit = (Some "500m"); cpu_request = None });
       replicas = 2; autoscaling = None; health_check = None; metrics = None; 
       logging = None; metadata = { Types.description = None; labels = []; annotations = [] };
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == providers/postgresql.loaf
  (Types.MService
     { Types.name = "postgresql"; runtime = "http";
       artifact =
       (Some { Types.path =
               "postgres:15-alpine@sha256:54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984";
               sha256 = "54e0dd8e8cddcdbb9156c2486eed5a43eccb7214d7c6828097d41ce049fb3984";
               format = "oci-image" });
       capability = (Some "database");
       inputs =
       [("dbname", "{consumer.name}_db"); ("password", "{generate.alnum(32)}");
         ("user", "{generate.alpha(12)}")];
       consumes = [];
       provides =
       [("dbname", "{input.dbname}"); ("host", "{service_name}"); ("password", "{input.password}");
         ("port", "5432"); ("user", "{input.user}")];
       readiness =
       (Some { Types.command = ["pg_isready"; "-U"; "{input.user}"]; readiness_interval = 5;
               readiness_timeout = 30 });
       security = None; ports = [{ Types.container = 5432; protocol = "tcp" }];
       environment =
       [("POSTGRES_DB", "{input.dbname}"); ("POSTGRES_PASSWORD", "{input.password}");
         ("POSTGRES_USER", "{input.user}")];
       resources = None; replicas = 1; autoscaling = None; health_check = None; 
       metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == providers/redis.loaf
  (Types.MService
     { Types.name = "redis"; runtime = "http";
       artifact =
       (Some { Types.path =
               "redis:7-alpine@sha256:8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f";
               sha256 = "8da19c7399dca900c6822a1cf30f9d2285585e2c4b457ff4095b0f4500054d3f";
               format = "oci-image" });
       capability = (Some "cache"); inputs = [("password", "{generate.alnum(32)}")]; 
       consumes = [];
       provides = [("host", "{service_name}"); ("password", "{input.password}"); ("port", "6379")];
       readiness =
       (Some { Types.command = ["redis-cli"; "-a"; "{input.password}"; "ping"];
               readiness_interval = 5; readiness_timeout = 30 });
       security = None; ports = [{ Types.container = 6379; protocol = "tcp" }];
       environment = [("REDIS_PASSWORD", "{input.password}")]; resources = None; 
       replicas = 1; autoscaling = None; health_check = None; metrics = None; 
       logging = None; metadata = { Types.description = None; labels = []; annotations = [] };
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == examples/enterprise-stack/web_api.loaf
  (Types.MService
     { Types.name = "web-api"; runtime = "http";
       artifact =
       (Some { Types.path = "./bin/web_api";
               sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
               format = "native-linux-amd64" });
       capability = None; inputs = [];
       consumes =
       [{ Types.name = "db"; capability = (Some "database"); service = None;
          provider = (Some "postgresql");
          inject =
          [("DATABASE_URL",
            "postgresql://{input.user}:{input.password}@{service_name}:5432/{input.dbname}")];
          mode = "request" }
         ];
       provides = []; readiness = None;
       security = (Some { Types.zone = "public"; route_labels = [] });
       ports = [{ Types.container = 8080; protocol = "tcp" }]; environment = [];
       resources =
       (Some { Types.memory_limit = (Some "512Mi"); memory_request = None; 
               cpu_limit = (Some "1"); cpu_request = None });
       replicas = 3;
       autoscaling =
       (Some { Types.min_replicas = 3; max_replicas = 10; cpu_threshold = (Some 70);
               memory_threshold = None });
       health_check = None; metrics = None; logging = None;
       metadata = { Types.description = None; labels = []; annotations = [] }; 
       storage = []; backup = None; secrets = []; placement = None; exposure = [] })
  == examples/enterprise-stack/organisation.loaf
  (Types.MPattern
     { Types.pat_name = "organisation"; pat_version = None; lattice = None; 
       zones = []; pat_assurance = []; pat_roles = ["admin"; "comptable"]; 
       constraints = []; objectives = [] })

  $ ../show.exe $R/provisioning-profiles/*.loaf $R/templates/bundles/dev-workstation/bundle.loaf | sed "s|$R/||"
  == provisioning-profiles/dev-workstation.loaf
  (Types.MProvisioningProfile
     { Types.pp_name = "dev-workstation";
       pp_os =
       { Types.os_image_name = "debian-12-amd64-genericcloud";
         os_url =
         "https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2";
         os_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
         os_format = "qcow2"; os_family = "debian"; os_raw_zst_url = ""; 
         os_raw_zst_sha256 = ""; os_bmap_url = "" };
       pp_bundles = [{ Types.bundle_name = "dev-workstation"; bundle_params = [] }];
       pp_cloud_init_extra = (Some "{runcmd: [systemctl enable --now ssh]}"); 
       pp_assurance = None })
  == provisioning-profiles/dev-workstation-demo.loaf
  (Types.MProvisioningProfile
     { Types.pp_name = "dev-workstation-demo";
       pp_os =
       { Types.os_image_name = "debian-12-amd64-genericcloud";
         os_url =
         "https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2";
         os_sha256 = "0000000000000000000000000000000000000000000000000000000000000000";
         os_format = "qcow2"; os_family = "debian"; os_raw_zst_url = ""; 
         os_raw_zst_sha256 = ""; os_bmap_url = "" };
       pp_bundles =
       [{ Types.bundle_name = "dev-workstation";
          bundle_params =
          [("full_name", (Types.PString "Example Developer"));
            ("ssh_public_keys",
             (Types.PList
                [(Types.PString
                    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE example@hamac")
                  ]));
            ("timezone", (Types.PString "Europe/Paris")); ("username", (Types.PString "devuser"))]
          }
         ];
       pp_cloud_init_extra = (Some "{runcmd: [systemctl enable --now ssh]}"); 
       pp_assurance = None })
  == templates/bundles/dev-workstation/bundle.loaf
  (Types.MBundle
     { Types.bdl_name = "dev-workstation"; bdl_version = "0.1.0";
       bdl_description = "Poste de dev minimal : utilisateur sudo, SSH, docker, dotfiles optionnels";
       bdl_params =
       [{ Types.param_name = "dotfiles_repo"; param_type = "string"; param_required = false };
         { Types.param_name = "full_name"; param_type = "string"; param_required = false };
         { Types.param_name = "initial_password"; param_type = "string"; param_required = false };
         { Types.param_name = "ssh_public_keys"; param_type = "list[string]"; 
           param_required = false };
         { Types.param_name = "timezone"; param_type = "string"; param_required = false };
         { Types.param_name = "username"; param_type = "string"; param_required = true }];
       bdl_depends_on = []; bdl_lifecycle = "install" })

Manifeste en plusieurs fichiers
==============================

Le langage fusionne les blocs d'un même sujet écrits dans plusieurs fichiers :
c'est un overlay, qui complète un manifeste depuis un autre fichier. Hamac le
signale (W003, une erreur avec `--strict`), parce que la même fusion cache
aussi deux définitions indépendantes d'un même nom.

  $ mkdir -p base prod
  $ cat > base/web.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.2.
  > service web {
  >   runtime http.
  >   artifact "registry.example.org/web@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
  >     sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".
  >     format oci_image.
  >   }
  > }
  > EOF
  $ printf 'loaf 0.1.\nuse hamac 0.2.\nservice web { replicas 3. }\n' > prod/web.loaf
  $ hamac validate base prod
  base/web.loaf: service (name=web, runtime=http)
  hamac: [WARNING] prod/web.loaf:3:1: [W003] service web is defined in base/web.loaf and prod/web.loaf
  $ hamac validate --strict base prod
  base/web.loaf: service (name=web, runtime=http)
  hamac: [WARNING] prod/web.loaf:3:1: [W003] service web is defined in base/web.loaf and prod/web.loaf
  [1]

Deux définitions indépendantes : leurs champs à une valeur se contredisent
(L006), en plus de l'avertissement.

  $ mkdir -p other
  $ cat > other/web.loaf <<'EOF'
  > loaf 0.1.
  > use hamac 0.2.
  > service web {
  >   runtime batch.
  >   artifact "registry.example.org/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" {
  >     sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".
  >     format oci_image.
  >   }
  > }
  > EOF
  $ hamac validate base other
  base/web.loaf: service (name=web, runtime=batch)
  hamac: [ERROR] base/web.loaf:4:3: [L006] service.runtime(web, http): the field has several values
  hamac: [ERROR] base/web.loaf:5:3: [L006] service.artifact(web, "registry.example.org/web@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"): the field has several values
  hamac: [ERROR] other/web.loaf:4:3: [L006] service.runtime(web, batch): the field has several values
  hamac: [ERROR] other/web.loaf:5:3: [L006] service.artifact(web, "registry.example.org/other@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"): the field has several values
  hamac: [WARNING] other/web.loaf:3:1: [W003] service web is defined in base/web.loaf and other/web.loaf
  [1]

Ordre des bundles
=================

Les cloud-init des bundles d'un profil sont fusionnés dans l'ordre de sa
liste `bundles`, le suivant l'emportant sur une valeur scalaire. Les
paramètres d'un bundle que la liste ne nomme pas sont refusés (E007).

  $ for b in first second; do
  >   mkdir -p bundles/$b
  >   printf 'loaf 0.1.\nuse hamac 0.2.\nbundle %s {}\n' $b > bundles/$b/bundle.loaf
  >   printf 'timezone: %s\n' $b > bundles/$b/cloud-init.yaml.j2
  > done
  $ profile () {
  >   printf 'loaf 0.1.\nuse hamac 0.2.\nprovisioning_profile p {\n  os "img" { url "http://x/img.qcow2". sha256 "%s". format qcow2. }\n  %s\n}\n' \
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

Le résolveur substitue les termes de l'instance du provider dans le gabarit
déjà rempli.

  $ hamac resolve --seed 42 -L $R/patterns $R/examples/hr-stack $R/providers 2>/dev/null | sed -n '/^Wiring/,$p'
  Wiring:
    hr-api.db -> postgresql
      inject: DATABASE_URL=postgresql://pottxvuimhan:z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs@postgresql-hr-api-db:5432/hr-api_db
    payroll-report.api -> hr-api (service)
      inject: HR_API_URL=http://hr-api:8080

Le plan d'une stack ne compte pas les providers comme des services ; il suit
le treillis de son patron. hr_api est réparti par domaine de panne (spread
failure_domain) : ses deux répliques occupent deux nœuds de rh, alors que la
zone tiendrait en volume sur un seul.

  $ (cd $R && hamac plan examples/hr-stack providers)
  Infrastructure proposal: stack-infra
  
  Minimum requirements:
    Nodes: 3
    RAM: 2560Mi
    CPU: 5 cores
  
  Zones:
    public: 1 service(s), 2 replica(s), 512 MB RAM, 1000 mCPU
      - portal
    rh: 2 service(s), 3 replica(s), 2048 MB RAM, 4000 mCPU
      - hr-api
      - payroll-report
  
  Proposed topology:
    1x node [public] — 4096Mi RAM, 4 CPU
    2x node [rh] — 4096Mi RAM, 4 CPU
  
  Network segments:
    public: 10.10.0.0/24 (VLAN 100)
    rh: 10.11.0.0/24 (VLAN 101)
  
  Firewall rules:
    DENY public -> rh (no read up)
    DENY rh -> public (no declared flow)
  
  hamac: [WARNING] soft constraint stateful_quorum of pattern exemple-rh (payroll-report) is violated

Le rendu d'un profil.

  $ hamac provision-dryrun --profile=$R/provisioning-profiles/dev-workstation-demo.loaf --bundles-dir=$R/templates/bundles
  === cloud-init ===
  #cloud-config
  # Généré par hamac pour le profile 'dev-workstation-demo'
  users:
  - name: devuser
    gecos: Example Developer
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: docker, sudo
    lock_passwd: true
    ssh_authorized_keys:
    - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLEEXAMPLE
      example@hamac
  timezone: Europe/Paris
  package_update: true
  packages:
  - git
  - vim
  - curl
  - ca-certificates
  - sudo
  - openssh-server
  - docker.io
  - python3
  - python3-pip
  - tmux
  - htop
  - jq
  - rsync
  write_files:
  - path: /etc/motd
    permissions: "0644"
    content: '============================================================
  
      Provisioned by hamac (bundle: dev-workstation)
  
      User: Example Developer (devuser)
  
      ============================================================
  
      '
  runcmd:
  - install -d -o devuser -g devuser /home/devuser/.config /home/devuser/.local/bin
    /home/devuser/projects
  - bash -c 'printf "\n# hamac/dev-workstation\nexport PATH=\"$HOME/.local/bin:$PATH\"\nalias
    ll=\"ls -lah\"\n" >> /home/devuser/.bashrc'
  - chown devuser:devuser /home/devuser/.bashrc
  - systemctl enable --now ssh || systemctl enable --now sshd
  - systemctl enable --now docker
  - usermod -aG docker devuser || true
  - echo "hamac dev-workstation provisioning done"
  - systemctl enable --now ssh
  
  === iPXE ===
  #!ipxe
  # Généré par hamac (provisioning_gen)
  # Image: debian-12-amd64-genericcloud (qcow2)
  
  set base-url https://cdimage.debian.org/cdimage/cloud/bookworm/latest
  kernel https://cdimage.debian.org/cdimage/cloud/bookworm/latest/vmlinuz initrd=initrd.img boot=live components
  initrd https://cdimage.debian.org/cdimage/cloud/bookworm/latest/initrd.img
  boot
  
  === OS ===
  url: https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
  sha256: 0000000000000000000000000000000000000000000000000000000000000000
  format: qcow2
