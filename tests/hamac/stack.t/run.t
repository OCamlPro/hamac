Trois services répartis sur trois zones de sécurité, consommant des providers
`database` et `cache`.

`plan` infère l'infrastructure : nœuds par zone, segments réseau et règles de
filtrage Bell-LaPadula (aucune de ces informations n'est écrite dans les
manifestes de service).

  $ hamac plan organisation.loaf analytics.loaf payroll.loaf web_api.loaf providers/*.loaf
  Infrastructure proposal: stack-infra
  
  Minimum requirements:
    Nodes: 8
    RAM: 13824Mi
    CPU: 27 cores
  
  Zones:
    internal: 1 service(s), 8 replica(s), 8192 MB RAM, 16000 mCPU
      - analytics
    public: 1 service(s), 10 replica(s), 5120 MB RAM, 10000 mCPU
      - web-api
    secure: 1 service(s), 2 replica(s), 512 MB RAM, 1000 mCPU
      - payroll
  
  Proposed topology:
    4x node [internal] — 4096Mi RAM, 4 CPU
    3x node [public] — 4096Mi RAM, 4 CPU
    1x node [secure] — 4096Mi RAM, 4 CPU (isolated)
  
  Network segments:
    internal: 10.10.0.0/24 (VLAN 100)
    public: 10.11.0.0/24 (VLAN 101)
    secure: 10.12.0.0/24 (VLAN 102)
  
  Firewall rules:
    DENY internal -> public (no declared flow)
    DENY internal -> secure (no read up)
    DENY public -> internal (no read up)
    DENY public -> secure (no read up)
    DENY secure -> internal (no declared flow)
    DENY secure -> public (no declared flow)
  

`resolve` apparie chaque `consumes` à un provider et génère les credentials.
`--seed` fixe la suite tirée : les valeurs ci-dessous sont donc vérifiées telles
quelles, y compris leur substitution dans les URL d'injection. Sans `--seed`,
elles viennent de /dev/urandom et changent à chaque exécution.

  $ hamac resolve --seed 42 analytics.loaf payroll.loaf web_api.loaf providers/*.loaf
  hamac: [WARNING] --seed 42: generated credentials are reproducible, hence predictable. Never use this for a real deployment.
  Providers to instantiate:
    redis-analytics-cache (redis:7-alpine)
      env: REDIS_PASSWORD=z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs
    postgresql-analytics-db (postgres:15-alpine)
      env: POSTGRES_DB=analytics_db
      env: POSTGRES_PASSWORD=1etrbNguG1sdz0MnC3n6uH1Pbi0QyUaA
      env: POSTGRES_USER=ateytyknqyqr
    postgresql-payroll-db (postgres:15-alpine)
      env: POSTGRES_DB=payroll_db
      env: POSTGRES_PASSWORD=pycXdfCZ9AemsKjLFMOjVgBs4xo20BSa
      env: POSTGRES_USER=xqtscxjpysjh
    postgresql-web-api-db (postgres:15-alpine)
      env: POSTGRES_DB=web-api_db
      env: POSTGRES_PASSWORD=oM2UtD0DZcfI9z5o8M5OwswpHEBuSHxX
      env: POSTGRES_USER=zhyvkxnbjymw
  
  Wiring:
    analytics.cache -> redis
      inject: REDIS_URL=redis://:z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs@redis-analytics-cache:6379
    analytics.db -> postgresql
      inject: DATABASE_URL=postgresql://ateytyknqyqr:1etrbNguG1sdz0MnC3n6uH1Pbi0QyUaA@postgresql-analytics-db:5432/analytics_db
    payroll.db -> postgresql
      inject: DATABASE_URL=postgresql://xqtscxjpysjh:pycXdfCZ9AemsKjLFMOjVgBs4xo20BSa@postgresql-payroll-db:5432/payroll_db
    web-api.db -> postgresql
      inject: DATABASE_URL=postgresql://zhyvkxnbjymw:oM2UtD0DZcfI9z5o8M5OwswpHEBuSHxX@postgresql-web-api-db:5432/web-api_db

`deploy` produit un docker-compose câblé : réseaux, variables injectées,
dépendances et healthchecks portant les credentials résolus.

  $ hamac deploy --seed 42 analytics.loaf payroll.loaf web_api.loaf providers/*.loaf
  hamac: [WARNING] --seed 42: generated credentials are reproducible, hence predictable. Never use this for a real deployment.
  hamac: [WARNING] deploy generates a flat docker-compose on a single network: it does not isolate the security zones (internal, public, secure). Use `hamac simulate` to deploy with zone filtering.
  Generated docker-compose.yml (3 services, 4 providers)
  $ grep -E '^(services|networks|  [a-z])' docker-compose.yml | head -20
  services:
    redis-analytics-cache:
    postgresql-analytics-db:
    postgresql-payroll-db:
    postgresql-web-api-db:
    analytics:
    payroll:
    web-api:
  networks:
    hamac:

Sans `--seed`, les credentials viennent de /dev/urandom : deux résolutions
successives des mêmes manifestes ne coïncident pas. C'est le comportement par
défaut, et c'est celui qui compte pour un déploiement réel.

  $ hamac resolve analytics.loaf providers/*.loaf > r1 2>&1
  $ hamac resolve analytics.loaf providers/*.loaf > r2 2>&1
  $ cmp -s r1 r2 && echo "identiques" || echo "differentes"
  differentes
