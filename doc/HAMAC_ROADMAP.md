# Hamac — Roadmap

Stack manager pour manifestes SIESTE. Approche "zero touch" : l'infrastructure est inferee a partir des contraintes des services, pas ecrite a la main.

## Milestone 1 — Parser et validation ✅

**Objectif** : Lire et valider les trois types de manifestes (`kind: service`, `kind: stack`, `kind: infrastructure`).

- [x] Parser YAML → types OCaml pour service manifest
- [x] Parser YAML → types OCaml pour stack manifest
- [x] Parser YAML → types OCaml pour infrastructure manifest
- [x] Validation des champs obligatoires et coherence (artifact.sha256, etc.)
- [x] Commande `hamac validate <files...>` (multi-fichier)
- [x] Messages d'erreur clairs avec chemin YAML dans l'erreur
- [x] Commande `hamac plan <files...>` (affichage des contraintes extraites)

## Milestone 2 — Resolution des providers ✅

**Objectif** : Resoudre les `consumes` d'un service vers des providers connus.

- [x] Registry local de providers (dossier `~/.hamac/providers/` ou `./providers/`)
- [x] Provider PostgreSQL (manifest provider de reference)
- [x] Provider Redis
- [x] Resolution : pour chaque `consumes`, trouver le provider correspondant
- [x] Generation de credentials aleatoires (user, password, dbname)
- [x] Substitution des templates `inject` avec les `provides` du provider
- [x] Commande `hamac resolve <files...>` avec affichage du cablage
- [x] Support des overrides de providers via stack manifest

## Milestone 3 — Deploiement docker-compose (compose plat) ✅

**Objectif** : Deployer une stack localement via docker-compose. Tremplin pour valider le cablage — le vrai objectif est la simulation d'infra (milestone 4).

- [x] Generer un `docker-compose.yml` a partir de services resolus
- [x] Cablage automatique : networks, env vars injectees, depends_on
- [x] Healthchecks avec credentials resolus (readiness → healthcheck)
- [x] Limites de ressources (memory, cpu)
- [x] Commande `hamac deploy <services.sieste.yml>`
- [ ] Commande `hamac status` (via `docker compose ps`) — differe
- [ ] Commande `hamac destroy` (via `docker compose down`) — differe

## Milestone 4 — Planner et simulation d'infrastructure ✅

**Objectif** : Inferer l'infrastructure necessaire a partir des services, puis simuler le deploiement avec des conteneurs DinD isolés par zone.

### Planner (inference d'infrastructure)

- [x] Extraction des contraintes depuis les services (RAM, CPU, zones, repliques)
- [x] Parsing des unites de ressources (Mi/Gi, millicores)
- [x] Calcul du nombre de noeuds par zone selon les ressources
- [x] Inference de la topologie reseau : un segment par zone avec CIDR et VLAN
- [x] Regles firewall automatiques Bell-LaPadula (deny higher → lower)
- [x] Generation d'un `infrastructure_manifest` proposal
- [x] Commande `hamac plan <services...>` avec affichage complet
- [x] Prise en compte de l'autoscaling (max_replicas) pour le dimensionnement

### Simulation d'infrastructure (DinD)

- [x] Un conteneur DinD (`docker:27-dind`) par noeud d'infra
- [x] Scripts d'init par noeud (wait Docker daemon, deploy replicas)
- [x] Noms de replicas uniques par noeud (service-0, service-1, ...)
- [x] Placement round-robin des replicas sur les noeuds de la zone
- [x] Reseaux docker isoles par zone de securite (subnets distincts)
- [x] Zone `secure` marquee `internal: true` (pas d'acces externe)
- [x] Providers dans la zone de leur consommateur
- [x] Commande `hamac simulate <services.sieste.yml>` avec affichage du placement
- [x] Scripts d'init idempotents (restart sans conflit de noms)
- [ ] Validation du firewall inter-zones (iptables/nftables dans les noeuds)
- [x] Tests d'integration avec `docker compose up`
  - Isolation DNS inter-zones validee (noms non resolus entre zones)
  - Isolation IP inter-zones validee (subnets distincts, 100% packet loss)
  - Credentials injectees correctement (DATABASE_URL, REDIS_URL)
  - Restart idempotent valide

### Demo

- [x] `demo/enterprise-stack/` : 3 services multi-zones (web_api/public, analytics/internal, payroll/secure)

## Milestone 5 — Discovery server integration

**Objectif** : Connecter le planner au parc reel via le discovery server.

- [ ] Client HTTP vers le discovery server (`tools/discovery-prototype/`)
- [ ] Inventaire du parc : machines disponibles, RAM, CPU, reseau
- [ ] Matching proposal ↔ parc reel
- [ ] Sortie "liste de courses" (ecart entre necessaire et disponible)
- [ ] Mode `--existing-infra <file>` pour infra fournie manuellement

## Milestone 6 — Deploiement bare-metal

**Objectif** : Provisionner des machines physiques via PXE/cloud-init.

- [ ] Generation de configurations cloud-init depuis le proposal
- [ ] Integration PXE pour boot initial
- [ ] Installation OS automatisee
- [ ] Configuration reseau (VLANs, subnets) automatisee
- [ ] Deploiement des services sur les machines provisionnees

## Milestone 7 — Backend QEMU/KVM

**Objectif** : Creer et gerer des VMs pour le deploiement.

- [ ] Generation de configurations libvirt
- [ ] Creation de VMs depuis images QCOW2
- [ ] Configuration reseau virtuel (bridges, VLANs)
- [ ] Deploiement des services dans les VMs

## Milestone 8 — Backend Kubernetes

**Objectif** : Deployer sur un cluster Kubernetes existant.

- [ ] Generation de manifestes K8s (Deployment, Service, ConfigMap, NetworkPolicy)
- [ ] NetworkPolicies automatiques depuis les labels de securite
- [ ] Commande `hamac deploy --backend=kubernetes`
- [ ] Rolling updates avec verification de sante

## Milestone 9 — Cycle de vie et updates

**Objectif** : Gestion continue de la stack deployee.

- [ ] `hamac update` : comparer deux manifestes, deployer les differences
- [ ] Rolling updates zero-downtime pour services HTTP
- [ ] Rollback automatique si health check echoue
- [ ] Historique des deployements

## Milestone 10 — Signature et securite

**Objectif** : Verification cryptographique des manifestes et artefacts.

- [ ] Signature Ed25519 des manifestes
- [ ] Verification des signatures avant deploiement
- [ ] Chain of trust : compilateur → manifest → stack manager

## Milestone 11 — Haute disponibilité des services à état (PostgreSQL) — état de l'art

**Objectif** : que les stacks générées par Hamac fournissent une **HA PostgreSQL
sans split-brain**, là où l'assemblage actuel (pgpool + repmgr, 2 nœuds) ne le
garantit pas.

**Motivation** : la stack SI OCP a subi des incidents récurrents de désync pgpool
puis un **split-brain** repmgr (2 nœuds sans quorum → un standby s'auto-promeut sur
un simple blip ; cf. `ocp-si`/`si` `DECISIONS.md` D4 + D5). L'**intérim** y est
`REPMGR_FAILOVER=manual` + une alerte Zulip `adminsys` ; la **HA définitive** a été
explicitement **déléguée à Hamac** plutôt que hand-rollée deux fois.

**Cible état de l'art** :
- [ ] Provider PostgreSQL HA générant **Patroni + DCS (etcd, ≥3 membres) + HAProxy**
      (routage via l'API REST Patroni `/primary` que le proxy health-check) →
      **fencing par DCS, split-brain impossible**.
- [ ] Alternative sur backend Kubernetes (Milestone 8) : opérateur **CloudNativePG**
      (gold standard k8s) au lieu de l'assemblage Patroni maison.
- [ ] Quorum réel (≥3 votants) : plus de promotion solitaire sur perte de contact.
- [ ] Reprise automatique d'un nœud divergé (`pg_rewind`/clone) sans intervention.
- [ ] Observabilité/alerting de l'état du cluster **dans la stack générée**
      (remplace la sonde intérimaire embarquée dans l'app ocp-si).

**À retirer côté SI une fois livré** : l'intérim D5 (`failover=manual` + sonde
`clusterHealthService` → Zulip `adminsys`).

---

## Financement

> « Ce projet a été financé par le gouvernement dans le cadre de France 2030 »
>
> « Financé par l'Union européenne - Next Generation EU dans le cadre du plan
> France Relance »

<p>
  <img src="assets/france-2030.png" alt="France 2030" height="48">
  &nbsp;&nbsp;
  <img src="assets/france-relance.png" alt="France Relance" height="48">
  &nbsp;&nbsp;
  <img src="assets/finance-par-union-europeenne-nextgenerationeu.png"
       alt="Financé par l'Union européenne — NextGenerationEU" height="48">
</p>

Provenance et règles d'usage des logos : [`assets/SOURCES.md`](assets/SOURCES.md).
