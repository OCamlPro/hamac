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

**Objectif** : Deployer une stack localement via docker-compose. Tremplin pour valider le cablage — le vrai objectif est la simulation d'infra (milestone 3b).

- [x] Generer un `docker-compose.yml` a partir de services resolus
- [x] Cablage automatique : networks, env vars injectees, depends_on
- [x] Healthchecks avec credentials resolus (readiness → healthcheck)
- [x] Limites de ressources (memory, cpu)
- [x] Commande `hamac deploy <services.sieste.yml>`
- [ ] Commande `hamac status` (via `docker compose ps`) — differe
- [ ] Commande `hamac destroy` (via `docker compose down`) — differe

## Milestone 3b — Simulation d'infrastructure

**Objectif** : Simuler des machines avec conteneurs (DinD/Sysbox), deployer les services a l'interieur, valider le placement et l'isolation reseau.

- [ ] Un conteneur par noeud d'infra (DinD ou Sysbox)
- [ ] Deploiement des services dans les noeuds (docker-in-docker)
- [ ] Reseaux docker isoles par zone de securite
- [ ] Placement des services sur les noeuds selon les contraintes
- [ ] Validation du firewall inter-zones

## Milestone 4 — Planner (inference d'infrastructure)

**Objectif** : A partir de service manifests, inferer les besoins en infrastructure.

- [ ] Extraction des contraintes depuis les services (RAM, CPU, zones, repliques)
- [ ] Regles de placement : anti-affinite entre zones de securite
- [ ] Inference de la topologie reseau depuis les labels Bell-LaPadula
- [ ] Regles firewall automatiques depuis les zones et route_labels
- [ ] Calcul du nombre de noeuds et du dimensionnement
- [ ] Generation d'un `kind: infrastructure` proposal
- [ ] Commande `hamac plan <services...>` → proposal YAML
- [ ] Warnings si l'infra fournie est sous-dimensionnee

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
