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
`--seed` fixe la suite tirée : les valeurs ci-dessous sont donc vérifiées telles
quelles, y compris leur substitution dans les URL d'injection. Sans `--seed`,
elles viennent de /dev/urandom et changent à chaque exécution.

  $ hamac resolve --seed 42 analytics.sieste.yml payroll.sieste.yml web_api.sieste.yml
  hamac: [WARNING] --seed 42: generated credentials are reproducible, hence predictable. Never use this for a real deployment.
  Loaded 2 provider(s) from ./providers
  Providers to instantiate:
    postgresql-analytics-db (postgres:15-alpine)
      env: POSTGRES_USER=jbkquuxmrgvc
      env: POSTGRES_PASSWORD=8NCONRJsMfb5QNVfDvXs1etrbNguG1sd
      env: POSTGRES_DB=analytics_db
    redis-analytics-cache (redis:7-alpine)
      env: REDIS_PASSWORD=z0MnC3n6uH1Pbi0QyUaAet6W5esZAe2B
    postgresql-payroll-db (postgres:15-alpine)
      env: POSTGRES_USER=jigxfhovnsau
      env: POSTGRES_PASSWORD=sKjLFMOjVgBs4xo20BSaR4zIuflNwunR
      env: POSTGRES_DB=payroll_db
    postgresql-web_api-db (postgres:15-alpine)
      env: POSTGRES_USER=gyagnnaxjktc
      env: POSTGRES_PASSWORD=9z5o8M5OwswpHEBuSHxXTNcPe1bDb8mi
      env: POSTGRES_DB=web_api_db
  
  Wiring:
    analytics.db -> postgresql
      inject: DATABASE_URL=postgresql://jbkquuxmrgvc:8NCONRJsMfb5QNVfDvXs1etrbNguG1sd@postgresql-analytics-db:5432/analytics_db
    analytics.cache -> redis
      inject: REDIS_URL=redis://:z0MnC3n6uH1Pbi0QyUaAet6W5esZAe2B@redis-analytics-cache:6379
    payroll.db -> postgresql
      inject: DATABASE_URL=postgresql://jigxfhovnsau:sKjLFMOjVgBs4xo20BSaR4zIuflNwunR@postgresql-payroll-db:5432/payroll_db
    web_api.db -> postgresql
      inject: DATABASE_URL=postgresql://gyagnnaxjktc:9z5o8M5OwswpHEBuSHxXTNcPe1bDb8mi@postgresql-web_api-db:5432/web_api_db

`deploy` produit un docker-compose câblé : réseaux, variables injectées,
dépendances et healthchecks portant les credentials résolus.

  $ hamac deploy --seed 42 analytics.sieste.yml payroll.sieste.yml web_api.sieste.yml
  hamac: [WARNING] --seed 42: generated credentials are reproducible, hence predictable. Never use this for a real deployment.
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

Sans `--seed`, les credentials viennent de /dev/urandom : deux résolutions
successives des mêmes manifestes ne coïncident pas. C'est le comportement par
défaut, et c'est celui qui compte pour un déploiement réel.

  $ hamac resolve analytics.sieste.yml > r1 2>&1
  $ hamac resolve analytics.sieste.yml > r2 2>&1
  $ cmp -s r1 r2 && echo "identiques" || echo "differentes"
  differentes
