# Hamac Provisioning Profile Specification v0.1

> **Statut** : draft — feature en cours d'implémentation (milestone 6 du `HAMAC_ROADMAP.md`).
> Ce document définit le contrat pour le provisionnement d'OS via PXE par hamac.

## 1. Objectif

Permettre à **hamac** de provisionner un OS complet (Linux base + services pré-configurés) sur n'importe quelle machine qui boote en PXE, qu'elle fasse partie de l'infrastructure SI ou non (typiquement : poste de développeur).

Cette première itération vit **entièrement côté hamac** (manifestes YAML + OCaml + prototype discovery). Une future couche UI / DSL côté langage SIESTE pour décrire ces profils visuellement reste possible (voir section 10) mais n'est **pas** dans le scope de cette spec.

## 2. Vue d'ensemble

```
                            ┌──────────────────────────────┐
                            │  provisioning_profile.yaml   │
                            │  (OS image + bundles list)   │
                            └──────────────┬───────────────┘
                                           │ référencé par
                                           ▼
                  ┌────────────────────────────────────┐
                  │  infrastructure manifest (hamac)   │
                  │  node.provisioning_profile: <name> │
                  └────────────────┬───────────────────┘
                                   │ hamac provision push
                                   ▼
                  ┌────────────────────────────────────┐
                  │  Discovery server                  │
                  │  - stocke profil par mac/id        │
                  │  - sert cloud-init agrégé          │
                  └────────────────┬───────────────────┘
                                   │ HTTP (depuis init PXE)
                                   ▼
                  ┌────────────────────────────────────┐
                  │  Machine en boot PXE               │
                  │  - télécharge cloud-init           │
                  │  - applique bundles                │
                  └────────────────────────────────────┘
```

## 3. Nouveau kind : `provisioning_profile`

Profil autonome, réutilisable entre plusieurs nœuds. Vit dans un fichier YAML séparé.

```yaml
manifest_version: "1.0"
kind: provisioning_profile
name: dev-workstation

os:
  image: debian-12-amd64
  url: https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
  sha256: 7e08e8e8e8e8...
  format: qcow2                  # qcow2 | raw | iso | netinstall

bundles:
  - name: dev-workstation
    params:
      username: julien
      ssh_public_keys:
        - "ssh-ed25519 AAAA..."
      dotfiles_repo: https://github.com/julien/dotfiles

cloud_init_extra:                # raw cloud-init pour cas spéciaux
  runcmd:
    - echo "Provisioned by hamac" > /etc/motd
  timezone: Europe/Paris
```

### Champs

| Champ | Type | Obligatoire | Description |
|---|---|---|---|
| `manifest_version` | string | oui | Toujours `"1.0"` pour cette version |
| `kind` | string | oui | Toujours `provisioning_profile` |
| `name` | string | oui | Identifiant unique, snake-case |
| `os` | object | oui | Image OS de base (voir 3.1) |
| `bundles` | list | non | Bundles à appliquer dans l'ordre (voir section 4) |
| `cloud_init_extra` | object | non | Fragment cloud-init mergé en dernier |

### 3.1 Bloc `os`

| Champ | Type | Obligatoire | Description |
|---|---|---|---|
| `image` | string | oui | Identifiant logique (humain) |
| `url` | string | oui | URL téléchargeable de l'image — référence canonique, consommée directement par les VMs |
| `sha256` | string | oui | Hash pour vérification |
| `format` | string | oui | `qcow2` \| `raw` \| `iso` \| `netinstall` |
| `raw_zst_url` | string | non | URL d'un raw disk image compressé zstd, dérivé de `url` à l'avance (voir ci-dessous) |
| `raw_zst_sha256` | string | non | Hash du `raw_zst_url` |
| `bmap_url` | string | non | URL du `.bmap` (block map, `bmaptool create`) associé au `raw_zst_url` |

`netinstall` signifie : on télécharge un initrd/kernel Debian standard et on lance un preseed.

#### Écriture des images « bloc » (`qcow2` / `raw`) sur le disque

Un disque cible contient des **octets bruts** ; le `qcow2` est un format de
*transport* (compressé, sparse) qui doit être « déplié » en raw avant d'être
écrit. hamac ne fait donc **pas** un `dd` du qcow2 tel quel :

- **`qcow2` = format canonique** d'un profil (source de vérité, aussi consommé
  tel quel par le chemin VM / `QemuCluster`) — `url`/`sha256`/`format`
  ci-dessus ne changent pas de sens quand `raw_zst_url`/`bmap_url` sont
  renseignés.
- Pour l'installation métal, hamac sert **deux artefacts dérivés
  déterministes** du qcow2 : un **`raw.zst`** (`qemu-img convert -O raw` +
  compression zstd) et son **`.bmap`** (`bmaptool create` — carte des blocs
  non-vides + sha256 par plage). Générés aujourd'hui par
  `tools/discovery-prototype/pxe-build/prepare-os-assets.sh`, invoqué par la
  CI (`build:hamac-discovery-image`, gated sur `provisioning-profiles/**`) et
  baqués dans l'image `hamac-discovery` (`/usr/share/hamac/images`, **hors**
  du volume Swarm persistant — un chemin dans le volume ne serait jamais
  ré-écrasé par un nouveau build après le premier déploiement).
- L'init écrit via **`bmaptool`** (embarqué dans l'initramfs — python3
  minimal + stdlib, pas de toolchain TLS complète) :
  ```
  blkdiscard <device>
  bmaptool copy <raw_zst_url> <device> --bmap <bmap_url>
  ```
  **Confirmé réellement** (pas juste documenté) : `bmaptool copy` accepte des
  URLs HTTP directement pour l'image *et* le `.bmap` — pas de téléchargement
  local préalable côté `pxe-build/init`. Il télécharge, décompresse à la
  volée, **n'écrit que les blocs mappés** et **vérifie le sha256 de chaque
  bloc** contre le `.bmap` — écriture minimale *et* intégrité forte, sans
  staging local. C'est strictement plus robuste qu'un sha256 global sur un
  fichier téléchargé nous-mêmes d'abord (`raw_zst_sha256`, ci-dessus, reste
  dans le schéma pour audit/outillage externe mais n'est plus le mécanisme
  de vérification actif de ce chemin).
- **Fallback** (si `raw_zst_url`/`bmap_url` sont absents, ou si l'initrd
  déployée ne connaît pas encore `bmaptool` — rollout) : `pxe-build/init`
  retombe silencieusement sur `url`/`format`/`sha256` — téléchargement local
  (`wget`) puis `qemu-img convert -O raw` (buildé statiquement from-source,
  pas le paquet apt : `qemu-utils` forcerait une vingtaine de paquets de
  dépendances transitives, TLS/PKCS#11 pour l'essentiel, hors de propos pour
  une conversion locale). Ce fallback **vérifie activement le sha256**
  (`os_image_sha256`) du fichier téléchargé avant écriture.
  - Le driver **curl** de qemu-img (streaming direct `qemu-img convert -f
    qcow2 -O raw -t none <URL> <device>`, sans copie locale intermédiaire)
    est buildé et fonctionnellement vérifié dans le binaire statique — le
    CDN Debian répond correctement aux requêtes HTTP Range nécessaires —
    mais **n'est pas utilisé aujourd'hui** : le qcow2 de référence (~330 Mo)
    tient sans souci dans le tmpfs de cette initrd, et le téléchargement
    local préserve la vérification sha256 active plutôt que de ne compter
    que sur TLS. À activer côté `pxe-build/init` si un futur profil sert une
    image sensiblement plus grosse ou vise du matériel avec peu de RAM.
  - `format: raw` fourni directement par l'ops (sans `raw_zst_url`/`bmap_url`)
    suit le même chemin, sans conversion (juste `dd`).
- **Connu manquant (pas encore implémenté)** : la génération *paresseuse* de
  `raw.zst`+`.bmap` par discovery à la première demande d'un profil qui n'en
  a pas encore (auto-promotion du fallback vers le chemin rapide+vérifié,
  sans dépendre d'une étape CI par profil). Aujourd'hui, un profil sans
  `raw_zst_url`/`bmap_url` renseignés reste **indéfiniment** sur le chemin
  qemu-img — pas d'auto-guérison. Suivi comme amélioration future, pas
  bloquant : le fallback fonctionne, juste sans le raccourci bmaptool.
- `blkdiscard` préalable (sans `-f` — pas d'option de ce nom dans la version
  busybox embarquée ; le binaire pris tel quel dans l'initrd netboot Debian
  officiel s'en sort très bien sans) pour que les zones non mappées relisent
  zéro en cas de ré-provisioning.
- **Resize au premier boot délégué à cloud-init** (`growpart` +
  `resize_rootfs`, activés par défaut sur les images cloud Debian, non
  désactivés par nos templates `templates/bundles/*/cloud-init*.yaml.j2`) :
  relocalise le GPT, étend la dernière partition et grossit le FS pour
  remplir un disque de taille quelconque — **pas d'outil de resize dans
  l'initramfs**.

## 4. Bundles

Un bundle est un répertoire `templates/bundles/<name>/` avec :

```
templates/bundles/dev-workstation/
├── bundle.yaml              # Métadonnées + paramètres acceptés
├── cloud-init.snippet.yaml.j2   # Fragment cloud-init mergé dans le profile
└── post-install/            # Scripts à exécuter dans l'OS provisionné
    ├── 10-dotfiles.sh
    └── 20-docker.sh
```

### 4.1 `bundle.yaml`

```yaml
manifest_version: "1.0"
kind: bundle
name: dev-workstation
version: "0.1.0"
description: "Poste de dev minimal : SSH, docker, dotfiles"

# Paramètres acceptés (validés par hamac avant push)
params:
  username:
    type: string
    required: true
  ssh_public_keys:
    type: list[string]
    required: true
  dotfiles_repo:
    type: string
    required: false

# Dépendances système (paquets installés via cloud-init)
packages:
  - git
  - docker.io
  - vim
  - curl

# Bundles qui doivent être appliqués avant celui-ci
depends_on: []

# Scripts post-install à lancer (ordre lexicographique)
post_install:
  - post-install/10-dotfiles.sh
  - post-install/20-docker.sh
```

### 4.2 Cloud-init snippet

Template Jinja2 qui produit un fragment de cloud-init. Les variables disponibles sont celles déclarées dans `params`.

```jinja2
{# cloud-init.snippet.yaml.j2 #}
users:
  - name: {{ params.username }}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
{% for key in params.ssh_public_keys %}
      - {{ key }}
{% endfor %}
{% if params.dotfiles_repo %}
write_files:
  - path: /home/{{ params.username }}/.config/dotfiles-repo
    content: "{{ params.dotfiles_repo }}"
    owner: "{{ params.username }}:{{ params.username }}"
{% endif %}
```

### 4.3 Règle de merge cloud-init

Quand plusieurs bundles produisent chacun un snippet cloud-init, hamac merge dans l'ordre :

1. Snippets bundles (ordre `bundles:` du profil)
2. `cloud_init_extra` du profil

Stratégie : pour les listes (`runcmd`, `packages`, `users`, etc.) → concaténation. Pour les scalaires (`timezone`, `hostname`) → le dernier gagne. Pour les blocs `write_files` → concaténation par chemin (collision détectée et signalée).

## 5. Référencement depuis `kind: infrastructure`

Le manifeste infrastructure existant (`doc/MANIFEST_SPEC.md`) reçoit un nouveau champ optionnel `provisioning_profile` au niveau de chaque node :

```yaml
manifest_version: "1.0"
kind: infrastructure
name: dev-fleet
backend: physical

proposed_topology:
  nodes:
    - role: workstation
      count: 5
      ram: 16GB
      cpu: 4
      boot: pxe
      provisioning_profile: dev-workstation   # ← NEW
```

Si `provisioning_profile` est présent, hamac **ignore** les anciens champs `os.image` / `os.sha256` du node (qui restent supportés pour la compat). Le profil prend le dessus.

Le profil est résolu par hamac via :
1. Recherche dans le dossier courant (`./provisioning-profiles/<name>.yaml`)
2. Recherche dans `$HAMAC_PROFILES_DIR/<name>.yaml`
3. Recherche dans `/etc/hamac/profiles/<name>.yaml`

## 6. CLI hamac

```bash
# Lister les profils disponibles
hamac provision list

# Valider un profil (params, hashs, bundles)
hamac provision validate ./provisioning-profiles/dev-workstation.yaml

# Pousser les profils d'une infrastructure vers le discovery server
hamac provision push infrastructure.yaml [--discovery=http://...]

# Afficher le cloud-init final qui serait poussé (dryrun)
hamac provision dryrun infrastructure.yaml --node=workstation-1

# Retirer un profil (pour un mac donné)
hamac provision clear --mac=aa:bb:cc:dd:ee:ff
```

## 7. Contrat discovery server

### 7.1 Storage

Le discovery server persiste les profils sur disque dans `$HAMAC_DISCOVERY_STATE/provisioning/<mac>.json` (par défaut `/var/lib/hamac-discovery/provisioning/`). Un redémarrage du discovery ne casse pas un boot PXE en cours.

Le contenu de chaque fichier est le **cloud-init final agrégé** (bundles + extra), pas le profil source. Tout le rendu Jinja2 a déjà eu lieu côté hamac. Le discovery est volontairement "bête" : il ne sait pas ce qu'est un bundle, il sert juste un blob YAML.

### 7.2 Endpoints ajoutés

| Méthode | Chemin | Description |
|---|---|---|
| `POST` | `/provisioning/<mac>` | hamac pousse un cloud-init pré-rendu pour ce mac |
| `GET` | `/provisioning/<mac>` | Le init PXE récupère son cloud-init |
| `DELETE` | `/provisioning/<mac>` | Retire l'association mac → profil |
| `GET` | `/provisioning` | Liste les associations (pour debug/dashboard) |

Format `POST /provisioning/<mac>` :

```json
{
  "profile_name": "dev-workstation",
  "cloud_init": "#cloud-config\n...",
  "ipxe_script": "#!ipxe\n...",
  "os_image_url": "https://...",
  "os_image_sha256": "...",
  "os_format": "qcow2",
  "os_raw_zst_url": "",
  "os_raw_zst_sha256": "",
  "os_bmap_url": ""
}
```

`os_raw_zst_url`/`os_raw_zst_sha256`/`os_bmap_url` sont vides quand le profil source n'a pas de `raw_zst_url`/`bmap_url` (§3.1) — chaîne vide, pas de champ absent, pour un parsing côté init plus simple.

Format `GET /provisioning/<mac>` : renvoie le même JSON, plus un champ `created_at` (timestamp Unix).

### 7.3 Endpoint existant à étendre

`GET /nodes/:id/cloud-init` continue à exister pour la rétro-compat K3s, mais consulte d'abord `/provisioning/<mac>` si présent.

## 8. Flux de bout en bout

1. Ops écrit `dev-workstation.yaml` (profile) + `dev-fleet.yaml` (infrastructure).
2. `hamac provision push dev-fleet.yaml` :
   - Résout le profil par nom
   - Pour chaque node avec une MAC connue (issue du planner ou fournie), génère le cloud-init final (templates Jinja2 + merge)
   - POST sur `/provisioning/<mac>` du discovery server
3. La machine boote en PXE → init script :
   - Detect MAC locale
   - GET `/provisioning/<mac>` → reçoit cloud-init + URL OS (+ éventuellement
     `os_raw_zst_url`/`os_bmap_url`, cf. §7.2)
   - Installe selon `format` (cf. §3.1) :
     - `qcow2` / `raw` → écrit l'image bloc sur le disque : `blkdiscard` puis,
       si `os_raw_zst_url`/`os_bmap_url` présents et `bmaptool` disponible
       dans l'initrd, `bmaptool copy` **directement depuis ces URLs**
       (streaming, décompression à la volée, vérification sha256 par bloc —
       pas de téléchargement local préalable) ; sinon fallback sur le chemin
       qcow2 historique : téléchargement local puis vérification sha256
       (`os_image_sha256`) puis `qemu-img convert` (ou `dd` direct si
       `format: raw`). Le resize de la partition est délégué à cloud-init au
       premier boot (`growpart` + `resize_rootfs`).
     - `netinstall` → preseed Debian ; `debootstrap` → bootstrap direct
   - Chroote, applique cloud-init dans le système installé
   - Lance les `post-install/*.sh`
   - Reboot
4. La machine boote sur l'OS installé → cloud-init s'applique en premier boot → user créé avec SSH key → dotfiles installés.

## 9. Hors scope (v0.1)

- **Multi-tenant** : un seul discovery server par fleet pour l'instant.
- **Signature des profils** : pourra être ajouté plus tard avec la même mécanique que les services (Ed25519).
- **Bundles avec dépendances cycliques** : non détecté ; on fait confiance à l'ops.
- **Mise à jour live d'un OS déjà provisionné** : ce n'est pas un agent de config (cf. Ansible / Salt). Le profil ne s'applique qu'au moment du PXE boot.
- **Bundles avec runtime state** (DB, etc.) : pas encore. Les services type Zulip avec PostgreSQL viendront via les `kind: stack` classiques de hamac.
- **Exposition côté langage SIESTE** : reportée (voir section 10).

## 10. Évolutions futures

### Court terme (post v0.1)
- `hamac provision dryrun <mac>` affichant le cloud-init final sans pousser (déjà mentionné en CLI mais à valider).
- Diff entre deux versions d'un profil.
- Profile inheritance (`extends: base-debian`).

### Moyen terme : couche UI / DSL côté SIESTE
Une fois la mécanique hamac stabilisée, le langage SIESTE pourra exposer une **DSL/UI** pour décrire les profils visuellement, par exemple :

```sieste
profile dev_workstation:
  os := debian_12_cloud
  bundles := [
    dev_workstation_bundle {
      username := "julien"
      ssh_public_keys := [...]
    }
  ]
```

Le compilateur sortirait alors le YAML attendu par hamac. C'est cohérent avec l'architecture déjà choisie pour les services (`#[service]` → manifeste YAML → hamac).

À ce moment-là, on pourra envisager :
- Validation typée des `params` de bundles via le système de types SIESTE
- Vue web (drag-and-drop) des profils, similaire à ce qui est prévu pour les clusters (typeclass `Cluster[C]`)
- Génération de profils paramétriques (`for u in users: profile(u)`)

### Long terme
- Signature Ed25519 des profils (parité avec les services).
- Provisioning d'OS containers (LXC, systemd-nspawn) en plus du bare-metal/VM.
- Gestion de versions avec rollback sur l'OS installé (A/B partitions).

## 11. Références

- `doc/MANIFEST_SPEC.md` : format des autres manifestes hamac
- `doc/BUNDLE_SPEC.md` : système de bundles deploy hamac (à ne pas confondre avec les bundles de provisioning)
- `doc/HAMAC_ROADMAP.md` : milestone 6
- `tools/discovery-prototype/discovery-server/discovery_server.ml` : prototype actuel
- `tools/discovery-prototype/pxe-build/init` : init script à étendre

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
