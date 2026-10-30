# hamac — repère pour Claude Code / contributeurs

**hamac** est un orchestrateur d'infrastructure : il lit des
manifestes déclaratifs écrits en LOAF (`*.loaf`), résout les dépendances de services vers des providers,
et provisionne/déploie — y compris le **provisioning bare-metal via PXE**. OCaml, AGPL-3.0
(+ licence commerciale). **Dépôt canonique sur Forgejo**
(`forge.ocamlpro.com/OSS/hamac`), GitHub est un **miroir read-only**.

## Où chercher (contrats, specs, état du projet)

- **`doc/typst/provisioning.typ`** — **LE contrat** du provisioning : format du manifeste
  `provisioning_profile`, gestion de l'image OS, chemin d'écriture disque (qcow2 canonique →
  `raw.zst` + `.bmap`, écriture via `bmaptool`, fallback `qemu-img` statique), resize au premier
  boot. À lire en premier pour comprendre le comportement de provisioning.
- **`doc/typst/manifest.typ`** — spécification du format de manifeste (0.2, brouillon) :
  `kind`, champs, stabilité, patrons et modèles de sécurité, catalogue des erreurs du
  validateur.
- **`doc/typst/control-plane.typ`** — modèle du plan de contrôle à tours (proposition).
- **`doc/HAMAC_ROADMAP.md`** — jalons et état d'avancement.
- **`pkgs/hamac-manifest/vocabulary/hamac.loaf`** — le vocabulaire LOAF de Hamac : blocs
  des manifestes (`service`, `pattern`, `stack`, `infrastructure`, `provisioning_profile`,
  `bundle`), contrats des capacités (`database`, `cache`), défauts et validations. À
  côté, les modèles de sécurité livrés : `hamac_blp.loaf` (Bell-LaPadula), `hamac_rbac.loaf`
  (rôles) et le patron `hamac_default.loaf` ; un modèle ajoute ses champs aux patrons et aux
  routes (`blp::level`, `rbac::role`) et définit `zone_leq`, l'ordre des zones.
- Les manifestes consommés sont des `*.loaf`, chargés en un ensemble (une stack avec ses
  services et les providers qu'ils consomment ; un dossier vaut ses `.loaf`, à toute
  profondeur : `hamac plan examples/hr-stack providers`) ; un patron est un module LOAF,
  chargé par `use` depuis un répertoire de bibliothèque (`hamac -L DIR`, `./patterns`,
  `~/.hamac/patterns`). Un manifeste défini dans plusieurs fichiers (overlay) donne W003. Langage : dépôt `~/ocp/loaf`, `spec/loaf.typ`.

## Documents officiels : Typst

Les spécifications, manuels et livrables sont écrits en **Typst** (`doc/typst/*.typ`, thème
commun `doc/typst/theme.typ` aux couleurs de la charte, pied de financement automatique) et
construits en PDF par `make -C doc` ; `make -C doc check` échoue au moindre avertissement.
Les PDF ne sont **pas versionnés** : la CI les produit. README, CONTRIBUTING, roadmap et
notes de travail restent en Markdown. Typst installé par snap ne peut pas écrire dans
`/tmp` : compiler vers un fichier sous `doc/`.

## Packages (OCaml, dépendances 100 % opam publiques)

- **`pkgs/hamac`** — la CLI `hamac` (cmdliner). Commandes : `validate`, `plan`, `resolve`,
  `simulate`, `deploy`, `status`, `provision-dryrun|push|clear`. Point d'entrée :
  `pkgs/hamac/main.ml`.
- **`pkgs/hamac-manifest`** — bibliothèque du format pivot, utilisable seule : `Types`,
  `Loaf_source` (chargeur LOAF → `Types`, vocabulaire trouvé par dune-site ou
  `HAMAC_VOCABULARY`), `Checks` (contrôles d'un manifeste que le vocabulaire n'exprime pas),
  `Diagnostic`, `Flows` (flux déclarés,
  règles de filtrage), `Stack_check` (chargement d'un ensemble, validation de l'étage 3). Tout code qui lit ou valide un
  manifeste passe par elle.
- **`pkgs/hamac-clingo`** — bibliothèque : liaison OCaml de libclingo (API C du solveur ASP
  clingo, stubs C `clingo_stubs.c`), sans dépendance à Hamac. Le planificateur
  (`pkgs/hamac/planner.ml`) résout avec elle la forme ASP des manifestes (`Loaf_source.asp`)
  augmentée de `pkgs/hamac/hamac.lp` (placement des répliques, embarqué dans l'exécutable)
  et des règles des contraintes et objectifs des patrons, écrites en ASP sur les prédicats
  que `hamac.lp` publie (`Planner.pattern_rules`, contrôlées par `Planner.check` : E052).
- **`pkgs/hamac-provisioning`** — bibliothèque : rendu du provisioning (cloud-init + iPXE,
  `provisioning_gen.ml`).
- **`pkgs/hamac-discovery`** — serveur de découverte : stocke un enregistrement de provisioning
  par MAC, sert le cloud-init agrégé aux machines qui bootent en PXE.
- **`docker/hamac-pxe`**, **`docker/hamac-discovery`** — images conteneur.
  `tools/discovery-prototype/` construit les assets PXE (kernel/initramfs, iPXE,
  `prepare-os-assets.sh`).

## Build

Toutes les dépendances OCaml sont des paquets opam publics ; s'y ajoute **libclingo** (clingo
5.x), dépendance système sans paquet Debian/Ubuntu. Sur le poste de dev, clingo 5.8.2 est
construit depuis ses sources dans `~/.local/clingo` : **toute commande dune passe
`CLINGO_PREFIX=$HOME/.local/clingo`** (découverte : `pkgs/hamac-clingo/config/discover.ml`),
par exemple `CLINGO_PREFIX=$HOME/.local/clingo opam++ exec --switch ~/ocp/hamac -- dune build`. Les fichiers de build sont **générés par
`marmiton`** depuis `recipe.yaml` — **éditer `recipe.yaml`, PAS les `dune`/`dune-project`/`opam/*`
générés** (ils portent l'en-tête « generated by marmiton, MUST NOT be edited »).

```sh
opam install --deps-only --with-test .
dune build
dune runtest
marmiton              # régénère dune/opam après édition de recipe.yaml (sans sous-commande)
```

Convention : les bibliothèques OCaml sont `(wrapped true)`.

Piège : sur le poste de dev, le binaire `~/ocp/marmiton/_build/install/default/bin/marmiton`
ne trouve pas ses greffons (« Using plugins: » vide, aucun fichier écrit) et aucun switch n'a
toutes ses dépendances pour le relancer par `dune exec`. Le 2026-10-19, l'ajout de
`hamac-manifest` a donc été reporté à la main dans les fichiers générés, sur le modèle exact des
autres paquets : à repasser par `marmiton` dès qu'il tourne, et vérifier que le diff est vide.

## CI — `.forgejo/workflows/ci.yml` (Forgejo Actions)

Tourne sur les runners Forgejo d'OCamlPro. Le job `build` construit libclingo (clingo 5.8.2,
archive du tag officiel vérifiée par sha256) dans `/usr/local` avant les dépendances opam :
Debian n'a pas de `libclingo-dev`. Garder la même version que sur les postes de dev (le plan
optimal retenu entre plans de même coût dépend du solveur). Trois contraintes apprises à la
dure — à **conserver** :

- **Pas de `container:` au niveau job** — les runners isolent les jobs (`docker_host: "-"`), donc
  un `container:` crée un conteneur imbriqué dont le `docker create` **pend**. Le job tourne dans
  l'image du label `docker` (`node:20-bookworm`), installe opam via `apt` et construit OCaml 5.3.0
  (`opam switch create . ocaml-base-compiler.5.3.0`) : la bibliothèque `loaf` exige OCaml ≥ 5.1,
  et elle est épinglée sur un tag de la forge (`pin-depends` de `opam/hamac-manifest.opam.template`).
- **Jobs `runs-on: dind`** : le label `dind` fait tourner le job **dans** l'image
  `docker:dind` (Alpine, `privileged: true`), avec `docker_host: "-"` côté runner.
  Deux conséquences à conserver : chaque step doit déclarer `shell: sh` (pas de
  bash dans l'image, et le `defaults` global du workflow impose bash ; un
  `defaults` au niveau job n'est pas honoré), et le **daemon Docker doit être
  démarré par le job lui-même** (`dockerd --host=unix:///var/run/docker.sock &`)
  — le runner n'injecte aucun socket et n'exécute pas l'entrypoint de l'image.
- **Cloner depuis l'URL publique** `https://forge.ocamlpro.com/…` — `GITHUB_SERVER_URL`
  (`http://forgejo:3000`) est un nom de service interne **non résolvable** depuis les conteneurs
  de job. Le checkout est fait à la main avec `git` (pas d'`actions/checkout`, qui dépendrait du
  proxy `code.forgejo.org`).

## Licence & contributions

Double licence : **AGPL-3.0** (`LICENSE`) + commerciale (`LICENSING.md`). Toute contribution
externe requiert le **CLA individuel OCamlPro** (`CLA.md`) — voir `CONTRIBUTING.md`. Le dépôt
canonique et les issues/MR sont sur **Forgejo** ; GitHub est un miroir read-only (ne pas y ouvrir
de PR).
