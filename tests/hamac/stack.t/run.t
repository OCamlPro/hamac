Trois services répartis sur trois zones de sécurité, consommant des providers
`database` et `cache`.

`plan` infère l'infrastructure : nœuds par zone, segments réseau et règles de
filtrage Bell-LaPadula (aucune de ces informations n'est écrite dans les
manifestes de service).

  $ hamac plan analytics.sieste.yml payroll.sieste.yml web_api.sieste.yml
  Infrastructure proposal: stack-infra
  
  Minimum requirements:
    Nodes: 8
    RAM: 13824Mi
    CPU: 27 cores
  
  Zones:
    internal: 1 service(s), 8 replica(s), 8192 MB RAM, 16000 mCPU
      - analytics
    public: 1 service(s), 10 replica(s), 5120 MB RAM, 10000 mCPU
      - web_api
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
    DENY internal -> public (Bell-LaPadula)
    ALLOW internal -> secure
    ALLOW public -> internal
    ALLOW public -> secure
    DENY secure -> internal (Bell-LaPadula)
    DENY secure -> public (Bell-LaPadula)
  

`resolve` apparie chaque `consumes` à un provider et génère les credentials.
Ceux-ci étant aléatoires, on les masque pour garder une sortie déterministe.

  $ hamac resolve analytics.sieste.yml payroll.sieste.yml web_api.sieste.yml \
  >   | sed -E -e 's/(USER|PASSWORD)=[A-Za-z0-9]+/\1=<generated>/' \
  >            -e 's#://[^@]*@#://<generated>@#'
  Loaded 2 provider(s) from ./providers
  Providers to instantiate:
    postgresql-analytics-db (postgres:15-alpine)
      env: POSTGRES_USER=<generated>
      env: POSTGRES_PASSWORD=<generated>
      env: POSTGRES_DB=analytics_db
    redis-analytics-cache (redis:7-alpine)
      env: REDIS_PASSWORD=<generated>
    postgresql-payroll-db (postgres:15-alpine)
      env: POSTGRES_USER=<generated>
      env: POSTGRES_PASSWORD=<generated>
      env: POSTGRES_DB=payroll_db
    postgresql-web_api-db (postgres:15-alpine)
      env: POSTGRES_USER=<generated>
      env: POSTGRES_PASSWORD=<generated>
      env: POSTGRES_DB=web_api_db
  
  Wiring:
    analytics.db -> postgresql
      inject: DATABASE_URL=postgresql://<generated>@postgresql-analytics-db:5432/analytics_db
    analytics.cache -> redis
      inject: REDIS_URL=redis://<generated>@redis-analytics-cache:6379
    payroll.db -> postgresql
      inject: DATABASE_URL=postgresql://<generated>@postgresql-payroll-db:5432/payroll_db
    web_api.db -> postgresql
      inject: DATABASE_URL=postgresql://<generated>@postgresql-web_api-db:5432/web_api_db

`deploy` produit un docker-compose câblé : réseaux, variables injectées,
dépendances et healthchecks portant les credentials résolus.

  $ hamac deploy analytics.sieste.yml payroll.sieste.yml web_api.sieste.yml
  Loaded 2 provider(s) from ./providers
  Generated docker-compose.yml (3 services, 4 providers)
  $ grep -E '^(services|networks|  [a-z])' docker-compose.yml | head -20
  services:
    postgresql-analytics-db:
    redis-analytics-cache:
    postgresql-payroll-db:
    postgresql-web_api-db:
    analytics:
    payroll:
    web_api:
  networks:
    hamac:
