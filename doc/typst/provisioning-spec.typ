// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com>

#import "theme.typ": *

#show: document-officiel.with(
  titre: "Spécification du provisioning",
  sous-titre: [Profils de provisioning, bundles, écriture de l'image OS sur le
    disque et contrat du serveur de découverte : le provisionnement d'OS par
    PXE avec Hamac.],
  nature: "Spécification",
  version: "0.1",
  date: "2026-10-19",
  statut: "brouillon",
)

#note[
  *Statut* : brouillon — fonctionnalité en cours d'implémentation (milestone 6
  de `HAMAC_ROADMAP.md`). Ce document définit le contrat pour le
  provisionnement d'OS via PXE par Hamac.
]

= Objectif

Permettre à *Hamac* de provisionner un OS complet (base Linux + services
préconfigurés) sur n'importe quelle machine qui démarre en PXE, qu'elle fasse
partie de l'infrastructure du SI ou non (typiquement : poste de développeur).

Cette première itération vit *entièrement côté Hamac* (manifestes YAML +
OCaml + prototype de découverte). Une couche de description de plus haut
niveau reste possible (voir @evolutions), mais n'entre pas dans le périmètre
de cette spécification.

= Vue d'ensemble

#schema(raw(
"                            ┌──────────────────────────────┐
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
                  └────────────────────────────────────┘"))

= Nouveau kind : `provisioning_profile`

Profil autonome, réutilisable entre plusieurs nœuds. Il vit dans un fichier
YAML séparé.

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

#heading(level: 2, numbering: none)[Champs]

#tableau((auto, auto, auto, 1fr),
  [Champ], [Type], [Obligatoire], [Description],
  [`manifest_version`], [string], [oui], [Toujours `"1.0"` pour cette version],
  [`kind`], [string], [oui], [Toujours `provisioning_profile`],
  [`name`], [string], [oui], [Identifiant unique, snake-case],
  [`os`], [object], [oui], [Image OS de base (voir @bloc-os)],
  [`bundles`], [list], [non], [Bundles à appliquer dans l'ordre (voir @bundles)],
  [`cloud_init_extra`], [object], [non], [Fragment cloud-init fusionné en dernier],
)

== Bloc `os` <bloc-os>

#tableau((auto, auto, auto, 1fr),
  [Champ], [Type], [Obligatoire], [Description],
  [`image`], [string], [oui], [Identifiant logique (humain)],
  [`url`], [string], [oui], [URL téléchargeable de l'image — référence
    canonique, consommée directement par les VM],
  [`sha256`], [string], [oui], [Hash pour vérification],
  [`format`], [string], [oui], [`qcow2` | `raw` | `iso` | `netinstall`],
  [`raw_zst_url`], [string], [non], [URL d'une image disque raw compressée en
    zstd, dérivée de `url` à l'avance (voir ci-dessous)],
  [`raw_zst_sha256`], [string], [non], [Hash du `raw_zst_url`],
  [`bmap_url`], [string], [non], [URL du `.bmap` (carte de blocs,
    `bmaptool create`) associé au `raw_zst_url`],
)

`netinstall` signifie : on télécharge un initrd/kernel Debian standard et on
lance un preseed.

=== Écriture des images « bloc » (`qcow2` / `raw`) sur le disque

Un disque cible contient des *octets bruts* ; le `qcow2` est un format de
_transport_ (compressé, sparse) qui doit être « déplié » en raw avant d'être
écrit. Hamac ne fait donc *pas* un `dd` du qcow2 tel quel :

- *`qcow2` = format canonique* d'un profil (source de vérité, aussi consommé
  tel quel par le chemin VM / `QemuCluster`) — `url`/`sha256`/`format`
  ci-dessus ne changent pas de sens quand `raw_zst_url`/`bmap_url` sont
  renseignés.
- Pour l'installation métal, Hamac sert *deux artefacts dérivés
  déterministes* du qcow2 : un *`raw.zst`* (`qemu-img convert -O raw` +
  compression zstd) et son *`.bmap`* (`bmaptool create` — carte des blocs
  non vides + sha256 par plage). Ils sont générés aujourd'hui par
  `tools/discovery-prototype/pxe-build/prepare-os-assets.sh`, invoqué par la
  CI (`build:hamac-discovery-image`, conditionné à `provisioning-profiles/**`)
  et intégrés à l'image `hamac-discovery` (`/usr/share/hamac/images`, *hors*
  du volume Swarm persistant — un chemin dans le volume ne serait jamais
  réécrasé par un nouveau build après le premier déploiement).
- L'init écrit via *`bmaptool`* (embarqué dans l'initramfs — python3
  minimal + stdlib, pas de chaîne TLS complète) :
  ```sh
  blkdiscard <device>
  bmaptool copy <raw_zst_url> <device> --bmap <bmap_url>
  ```
  *Confirmé réellement* (pas seulement documenté) : `bmaptool copy` accepte
  des URL HTTP directement pour l'image _et_ le `.bmap` — pas de
  téléchargement local préalable côté `pxe-build/init`. Il télécharge,
  décompresse à la volée, *n'écrit que les blocs mappés* et *vérifie le
  sha256 de chaque bloc* contre le `.bmap` — écriture minimale _et_ intégrité
  forte, sans copie locale intermédiaire. C'est strictement plus robuste qu'un
  sha256 global sur un fichier que nous aurions d'abord téléchargé nous-mêmes
  (`raw_zst_sha256`, ci-dessus, reste dans le schéma pour l'audit et
  l'outillage externe mais n'est plus le mécanisme de vérification actif de ce
  chemin).
- *Repli* (si `raw_zst_url`/`bmap_url` sont absents, ou si l'initrd déployée
  ne connaît pas encore `bmaptool` — déploiement progressif) :
  `pxe-build/init` retombe silencieusement sur `url`/`format`/`sha256` —
  téléchargement local (`wget`) puis `qemu-img convert -O raw` (construit
  statiquement depuis les sources, pas le paquet apt : `qemu-utils`
  forcerait une vingtaine de paquets de dépendances transitives, TLS/PKCS\#11
  pour l'essentiel, hors de propos pour une conversion locale). Ce repli
  *vérifie activement le sha256* (`os_image_sha256`) du fichier téléchargé
  avant écriture.
  - Le pilote *curl* de qemu-img (streaming direct
    `qemu-img convert -f qcow2 -O raw -t none <URL> <device>`, sans copie
    locale intermédiaire) est construit et fonctionnellement vérifié dans le
    binaire statique — le CDN Debian répond correctement aux requêtes HTTP
    Range nécessaires — mais *n'est pas utilisé aujourd'hui* : le qcow2 de
    référence (\~330 Mo) tient sans souci dans le tmpfs de cette initrd, et le
    téléchargement local préserve la vérification sha256 active plutôt que de
    ne compter que sur TLS. À activer côté `pxe-build/init` si un futur profil
    sert une image sensiblement plus grosse ou vise du matériel avec peu de
    RAM.
  - `format: raw` fourni directement par l'exploitant (sans
    `raw_zst_url`/`bmap_url`) suit le même chemin, sans conversion (juste
    `dd`).
- *Manque connu (pas encore implémenté)* : la génération _paresseuse_ de
  `raw.zst` + `.bmap` par le serveur de découverte à la première demande d'un
  profil qui n'en a pas encore (promotion automatique du repli vers le chemin
  rapide et vérifié, sans dépendre d'une étape CI par profil). Aujourd'hui, un
  profil sans `raw_zst_url`/`bmap_url` renseignés reste *indéfiniment* sur le
  chemin qemu-img — pas d'auto-guérison. Suivi comme amélioration future, non
  bloquant : le repli fonctionne, simplement sans le raccourci bmaptool.
- `blkdiscard` préalable (sans `-f` — pas d'option de ce nom dans la version
  busybox embarquée ; le binaire pris tel quel dans l'initrd netboot Debian
  officielle s'en sort très bien sans) pour que les zones non mappées relisent
  zéro en cas de reprovisionnement.
- *Redimensionnement au premier démarrage délégué à cloud-init* (`growpart` +
  `resize_rootfs`, activés par défaut sur les images cloud Debian, non
  désactivés par nos gabarits `templates/bundles/*/cloud-init*.yaml.j2`) :
  relocalise la GPT, étend la dernière partition et agrandit le système de
  fichiers pour remplir un disque de taille quelconque — *pas d'outil de
  redimensionnement dans l'initramfs*.

= Bundles <bundles>

Un bundle est un répertoire `templates/bundles/<name>/` contenant :

```
templates/bundles/dev-workstation/
├── bundle.yaml              # Métadonnées + paramètres acceptés
├── cloud-init.snippet.yaml.j2   # Fragment cloud-init mergé dans le profile
└── post-install/            # Scripts à exécuter dans l'OS provisionné
    ├── 10-dotfiles.sh
    └── 20-docker.sh
```

== `bundle.yaml`

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

== Fragment cloud-init

Gabarit Jinja2 qui produit un fragment de cloud-init. Les variables
disponibles sont celles déclarées dans `params`.

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

== Règle de fusion cloud-init

Quand plusieurs bundles produisent chacun un fragment cloud-init, Hamac les
fusionne dans l'ordre :

+ fragments des bundles (ordre `bundles:` du profil) ;
+ `cloud_init_extra` du profil.

Stratégie : pour les listes (`runcmd`, `packages`, `users`, etc.) →
concaténation. Pour les scalaires (`timezone`, `hostname`) → le dernier
gagne. Pour les blocs `write_files` → concaténation par chemin (collision
détectée et signalée).

= Référencement depuis `kind: infrastructure`

Le manifeste d'infrastructure existant (voir la spécification du format de
manifeste, `doc/typst/manifest-spec.typ`) reçoit un nouveau champ optionnel
`provisioning_profile` au niveau de chaque nœud :

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

Si `provisioning_profile` est présent, Hamac *ignore* les anciens champs
`os.image` / `os.sha256` du nœud (qui restent supportés pour la
compatibilité). Le profil prend le dessus.

Le profil est résolu par Hamac via :

+ une recherche dans le dossier courant (`./provisioning-profiles/<name>.yaml`) ;
+ une recherche dans `$HAMAC_PROFILES_DIR/<name>.yaml` ;
+ une recherche dans `/etc/hamac/profiles/<name>.yaml`.

= CLI Hamac

```sh
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

= Contrat du serveur de découverte

== Stockage

Le serveur de découverte persiste les profils sur disque dans
`$HAMAC_DISCOVERY_STATE/provisioning/<mac>.json` (par défaut
`/var/lib/hamac-discovery/provisioning/`). Un redémarrage du serveur ne casse
pas un démarrage PXE en cours.

Le contenu de chaque fichier est le *cloud-init final agrégé* (bundles +
extra), pas le profil source. Tout le rendu Jinja2 a déjà eu lieu côté Hamac.
Le serveur de découverte est volontairement « bête » : il ne sait pas ce
qu'est un bundle, il sert juste un blob YAML.

== Points d'accès ajoutés <endpoints>

#tableau((auto, auto, 1fr),
  [Méthode], [Chemin], [Description],
  [`POST`], [`/provisioning/<mac>`], [Hamac pousse un cloud-init prérendu
    pour cette MAC],
  [`GET`], [`/provisioning/<mac>`], [L'init PXE récupère son cloud-init],
  [`DELETE`], [`/provisioning/<mac>`], [Retire l'association MAC → profil],
  [`GET`], [`/provisioning`], [Liste les associations (débogage, tableau de
    bord)],
)

Format de `POST /provisioning/<mac>` :

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

`os_raw_zst_url`/`os_raw_zst_sha256`/`os_bmap_url` sont vides quand le profil
source n'a pas de `raw_zst_url`/`bmap_url` (@bloc-os) — chaîne vide, pas de
champ absent, pour simplifier l'analyse côté init.

Format de `GET /provisioning/<mac>` : renvoie le même JSON, plus un champ
`created_at` (horodatage Unix).

== Point d'accès existant à étendre

`GET /nodes/:id/cloud-init` continue d'exister pour la rétrocompatibilité
K3s, mais consulte d'abord `/provisioning/<mac>` s'il est présent.

= Flux de bout en bout

+ L'exploitant écrit `dev-workstation.yaml` (profil) + `dev-fleet.yaml`
  (infrastructure).
+ `hamac provision push dev-fleet.yaml` :
  - résout le profil par son nom ;
  - pour chaque nœud dont la MAC est connue (issue du planner ou fournie),
    génère le cloud-init final (gabarits Jinja2 + fusion) ;
  - envoie un POST sur `/provisioning/<mac>` du serveur de découverte.
+ La machine démarre en PXE → script d'init :
  - détecte la MAC locale ;
  - `GET /provisioning/<mac>` → reçoit le cloud-init + l'URL de l'OS (+
    éventuellement `os_raw_zst_url`/`os_bmap_url`, cf. @endpoints) ;
  - installe selon `format` (cf. @bloc-os) :
    - `qcow2` / `raw` → écrit l'image bloc sur le disque : `blkdiscard` puis,
      si `os_raw_zst_url`/`os_bmap_url` sont présents et `bmaptool`
      disponible dans l'initrd, `bmaptool copy` *directement depuis ces URL*
      (streaming, décompression à la volée, vérification sha256 par bloc —
      pas de téléchargement local préalable) ; sinon repli sur le chemin
      qcow2 historique : téléchargement local, puis vérification sha256
      (`os_image_sha256`), puis `qemu-img convert` (ou `dd` direct si
      `format: raw`). Le redimensionnement de la partition est délégué à
      cloud-init au premier démarrage (`growpart` + `resize_rootfs`) ;
    - `netinstall` → preseed Debian ; `debootstrap` → amorçage direct ;
  - entre dans le système installé (chroot) et y applique cloud-init ;
  - lance les `post-install/*.sh` ;
  - redémarre.
+ La machine démarre sur l'OS installé → cloud-init s'applique au premier
  démarrage → utilisateur créé avec sa clé SSH → dotfiles installés.

= Hors périmètre (v0.1)

- *Multi-tenant* : un seul serveur de découverte par flotte pour l'instant.
- *Signature des profils* : pourra être ajoutée plus tard avec la même
  mécanique que les services (Ed25519).
- *Bundles avec dépendances cycliques* : non détectés ; on fait confiance à
  l'exploitant.
- *Mise à jour à chaud d'un OS déjà provisionné* : ce n'est pas un agent de
  configuration (cf. Ansible / Salt). Le profil ne s'applique qu'au moment du
  démarrage PXE.
- *Bundles avec état d'exécution* (base de données, etc.) : pas encore. Les
  services de type Zulip avec PostgreSQL viendront via les `kind: stack`
  classiques de Hamac.
- *Description depuis un langage de plus haut niveau* : reportée (voir
  @evolutions).

= Évolutions futures <evolutions>

== Court terme (après v0.1)

- `hamac provision dryrun <mac>` affichant le cloud-init final sans pousser
  (déjà mentionné dans la CLI, mais à valider).
- Diff entre deux versions d'un profil.
- Héritage de profils (`extends: base-debian`).

== Moyen terme : description de plus haut niveau

Une fois la mécanique stabilisée, un langage ou un outil de plus haut niveau
pourra produire les profils, comme il peut déjà produire des manifestes de
service : le format pivot le permet sans changement côté Hamac. On pourra
alors envisager :

- la validation typée des `params` de bundles ;
- une vue web des profils ;
- la génération de profils paramétriques, par exemple un profil par
  utilisateur.

== Long terme

- Signature Ed25519 des profils (parité avec les services).
- Provisioning de conteneurs d'OS (LXC, systemd-nspawn) en plus du
  bare-metal et des VM.
- Gestion de versions avec retour arrière sur l'OS installé (partitions A/B).

= Références

- `doc/typst/manifest-spec.typ` : spécification du format de manifeste
  (format des autres manifestes Hamac).
- `doc/BUNDLE_SPEC.md` : système de bundles de déploiement Hamac (à ne pas
  confondre avec les bundles de provisioning).
- `doc/HAMAC_ROADMAP.md` : milestone 6.
- `tools/discovery-prototype/discovery-server/discovery_server.ml` :
  prototype actuel.
- `tools/discovery-prototype/pxe-build/init` : script d'init à étendre.
