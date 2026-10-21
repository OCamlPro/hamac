// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com>

#import "theme.typ": *

#show: document-officiel.with(
  titre: "Spécification du format de manifeste",
  sous-titre: [Description des manifestes Hamac et des vérifications
    effectuées à leur chargement.],
  nature: "Spécification",
  version: "1.1",
  date: "2026-10-19",
  statut: "brouillon",
  reference: [Hyper Open X — jalon J2],
)

= Objet et principes

Ce document définit le format pivot `hamac-manifest`. Un manifeste conforme
peut être écrit à la main ou produit par un script, un langage de plus haut
niveau ou tout autre générateur. Ce document
remplace la description implicite que donnaient jusqu'ici le code et les
exemples.

L'implémentation de référence est la bibliothèque `hamac-manifest`
(`pkgs/hamac-manifest/`). Elle permet de lire et de valider des manifestes
sans dépendre du reste de Hamac.

== Principes

+ *Infrastructure inférée.* Un service déclare ses besoins : ressources,
  dépendances, sensibilité, stockage. Hamac calcule une topologie qui les
  satisfait. Un manifeste de service ne nomme aucune machine.
+ *Un auteur par `kind`.* Le développeur écrit `service`. L'opérateur écrit
  `stack` et choisit des `pattern`, que le responsable de la sécurité écrit ou
  adopte. Le planner produit `infrastructure`. L'administrateur du parc écrit
  `provisioning_profile` et `bundle`.
+ *Secrets par référence.* Aucun champ du format ne contient de secret en
  clair.
+ *Validation stricte.* Un champ inconnu, une référence non résolue ou un flux
  contraire au treillis entraînent le refus du manifeste. Le diagnostic donne
  le chemin YAML et un code (@validation).
+ *Stabilité.* La sémantique d'un champ #stable ne change pas au sein d'une
  version majeure (@versions).

Les mots #doit, #doit-pas, #devrait et #peut ont le sens des RFC 2119 et 8174.

= Versionnement et stabilité <versions>

== `manifest_version`

Chaque manifeste porte `manifest_version: "<majeure>.<mineure>"`.

- Une *version mineure* n'ajoute que des champs optionnels, des valeurs
  d'énumération ou des `kind`. Un manifeste valide en `1.0` reste valide en
  `1.1`, avec la même sémantique.
- Une *version majeure* peut retirer ou changer un champ. Elle s'accompagne
  d'un outil de migration (`hamac migrate`).
- Un outil qui implémente la version `M.m` :
  - #doit accepter tout manifeste `M.k` avec `k ≤ m` ;
  - #doit refuser un manifeste `M.k` avec `k > m` (#code("E002")), en
    indiquant la version qu'il implémente : il ne peut pas savoir ce que
    signifient des champs plus récents ;
  - #doit refuser une version majeure différente (#code("E002")).

== Niveaux de stabilité

Chaque champ de ce document porte l'un de ces niveaux :

#tableau((auto, 1fr),
  [Niveau], [Garantie],
  stable, [sémantique figée pour toute la version majeure],
  experimental, [peut changer dans une version mineure ; son usage produit
    l'avertissement #code("W001"), sauf si la stack déclare
    `accept_experimental: true`],
  deprecie, [accepté, avec l'avertissement #code("W002") qui nomme le
    remplaçant ; retiré à la version majeure suivante],
)

En 1.1 sont #experimental : `storage`, `backup`, `placement`, `secrets`,
`exposure`, les axes d'assurance, contraintes et objectifs de
`kind: pattern`, le mode `push` des flux et le cycle de vie `converge` des
bundles. Le reste est #stable.

== Champs inconnus et extensions

- Un champ inconnu à un emplacement défini par ce document est une erreur
  (#code("E003")). Cette règle détecte notamment les fautes de frappe, comme
  `replica: 3`.
- Les champs dont le nom commence par `x-` sont des extensions. Ils
  #peut apparaître dans tout objet ; Hamac les ignore et les conserve. Un
  générateur tiers peut y placer ses propres données.
- `metadata.annotations` (@enveloppe) accepte aussi des données libres.

= Enveloppe commune <enveloppe>

#stable

```yaml
manifest_version: "1.1"
kind: service            # service | pattern | stack | infrastructure
                         # | provisioning_profile | bundle
name: hr-api
metadata:                # optionnel
  description: "API des ressources humaines"
  labels:                # clés/valeurs courtes, pour les sélecteurs
    team: rh
  annotations:           # texte libre, ignoré par Hamac
    example.org/generated-from: "hr/api"
```

#tableau((auto, 1.3fr, auto, 2fr),
  [Champ], [Type], [Requis], [Règle],
  [`manifest_version`], [chaîne `M.m`], [oui], [@versions],
  [`kind`], [énumération], [oui en 1.1], [en `1.0`, l'absence de `kind` vaut
    `service` (#deprecie, #code("W002"))],
  [`name`], [chaîne], [oui], [*nom DNS* :
    `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$` (#code("E004")). Les manifestes
    `1.0` acceptent aussi `_`, avec #code("W002") : un nom de service devient
    un nom d'hôte, et `_` n'y est pas admis],
  [`metadata.description`], [chaîne], [non], [],
  [`metadata.labels`], [table], [non], [clés
    `^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?$`],
  [`metadata.annotations`], [table], [non], [],
  [`signature`], [objet], [non], [*réservé* à la signature des manifestes
    (version ultérieure) ; refusé en 1.1 (#code("E003"))],
)

Les noms sont uniques par `kind` au sein d'une stack (#code("E010")).

= Gabarits <gabarits>

#stable

Certaines chaînes sont des *gabarits* : les segments `{expression}` y sont
remplacés à la résolution. `{{` et `}}` produisent des accolades littérales.

#tableau((auto, 1.4fr, 1fr),
  [Expression], [Valeur], [Où],
  [`{generate.alpha(n)}`], [`n` lettres minuscules tirées au hasard],
    [`inputs` d'un provider],
  [`{generate.alnum(n)}`], [`n` caractères alphanumériques],
    [`inputs` d'un provider],
  [`{input.<clé>}`], [valeur résolue d'un `inputs` du provider],
    [`provides`, `environment`, `readiness` d'un provider],
  [`{consumer.name}`], [nom du service consommateur], [`inputs` d'un provider],
  [`{service_name}`], [nom du service courant], [partout dans un service],
  [`{<clé>}`], [valeur `provides.<clé>` du provider ou du service consommé ;
    pour un service, aussi `{host}`, `{port}` et `{service_name}`, qui le
    désignent], [`consumes[].inject`],
  [`{secret.<nom>}`], [référence à un secret déclaré (@secrets)
    #experimental], [`environment`, `consumes[].inject`],
)

- Le tirage aléatoire utilise le générateur cryptographique du système ;
  l'option `--seed` le rend reproductible pour les tests.
- Une expression inconnue, ou une clé absente du `provides` consommé, est une
  erreur (#code("E020")).
- La valeur d'un `{secret.x}` n'est écrite dans aucun fichier généré.
  L'agent l'injecte au démarrage du service (@secrets).

= `kind: service` <service>

Un service est une unité déployable. Un #terme[provider] est un service qui
déclare une `capability` et des `provides`, et que d'autres services
consomment : base de données, cache, stockage objet, etc. Un provider se
décrit par un manifeste ; en ajouter un ne demande pas de recompiler Hamac.

== Vue d'ensemble

```yaml
manifest_version: "1.1"
kind: service
name: hr-api
runtime: http

artifact:
  path: registry.example.org/rh/hr-api@sha256:4f0c…
  sha256: "4f0c…"
  format: oci-image

consumes:
  - name: db
    capability: database
    inject:
      DATABASE_URL: "postgresql://{user}:{password}@{host}:{port}/{dbname}"
  - name: files
    capability: object-storage
    inject:
      S3_ENDPOINT: "{endpoint}"
      S3_BUCKET: "{bucket}"
      S3_ACCESS_KEY: "{access_key}"
      S3_SECRET_KEY: "{secret_key}"

security:
  zone: rh
  route_labels:
    - route: /health
      public: true
    - route: /employees/salaries
      classification: internal
      categories: [rh]
      required_clearance: [comptable, admin]

ports:
  - container: 8080
    protocol: tcp

exposure:                       # expérimental
  - hostname: rh.example.org
    port: 8080
    tls: acme

resources:
  memory_limit: 512Mi
  cpu_limit: "1"

replicas: 2

health_check:
  path: /health
  interval: 10
  timeout: 3
  retries: 3
```

== Champs

#tableau((auto, 1.3fr, auto, 2fr),
  [Champ], [Type], [Stabilité], [Sémantique],
  [`runtime`], [`http` · `cli` · `batch` · `eventloop` · `custom`], stable,
    [nature de la charge, obligatoire ; `http` active les sondes HTTP et
    l'exposition],
  [`artifact`], [objet, @artifact], stable, [ce qui s'exécute ; obligatoire
    sauf pour un provider abstrait],
  [`capability`], [chaîne], stable, [fait du service un provider de cette
    capacité],
  [`inputs`], [table → gabarit], stable, [valeurs générées une fois par
    consommateur (provider)],
  [`provides`], [table → gabarit], stable, [ce que le provider expose à ses
    consommateurs],
  [`readiness`], [objet, @sondes], stable, [commande de disponibilité d'un
    provider],
  [`consumes`], [liste, @consumes], stable, [dépendances et flux réseau
    déclarés],
  [`security`], [objet, @security], stable, [zone et étiquettes
    d'autorisation ; absent ⇒ zone `default`],
  [`ports`], [liste, @ports], stable, [ports écoutés],
  [`environment`], [table → gabarit], stable, [variables d'environnement],
  [`resources`], [objet, @sondes], stable, [requêtes et limites],
  [`replicas`], [entier ≥ 1, défaut 1], stable, [nombre d'instances],
  [`autoscaling`], [objet, @sondes], stable, [bornes de mise à l'échelle],
  [`health_check`], [objet, @sondes], stable, [sonde de santé],
  [`metrics`], [objet, @sondes], stable, [point de collecte],
  [`logging`], [objet, @sondes], stable, [format et niveau],
  [`volumes`], [liste], deprecie, [chemin d'hôte ; remplacé par `storage`
    (#code("W002")). Interdit avec `storage` (#code("E030"))],
  [`storage`], [liste, @storage], experimental, [volumes de système de
    fichiers, par classe],
  [`backup`], [objet, @storage], experimental, [politique de sauvegarde],
  [`secrets`], [liste, @secrets], experimental, [références de secrets],
  [`placement`], [objet, @placement], experimental, [capacités et niveaux
    d'assurance requis],
  [`exposure`], [liste, @exposure], experimental, [publication en bordure],
)

== `artifact` <artifact>

#stable

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`path`], [chaîne], [chemin, URL ou référence OCI ; une référence OCI
    #devrait être épinglée par empreinte (`@sha256:…`), sinon
    #code("W010")],
  [`sha256`], [64 caractères hexadécimaux], [empreinte de l'artefact
    (#code("E011") si le format est faux)],
  [`format`], [`oci-image` · `native-linux-amd64` · `native-linux-arm64` ·
    `incus-vm-image` · `incus-system-image`], [détermine l'exécutant :
    conteneur, binaire natif, VM ou conteneur système],
)

Le format détermine aussi le mode d'exécution : un artefact `incus-vm-image`
s'exécute dans une VM, un `oci-image` dans un conteneur. Aucun autre champ ne
le précise.

== `consumes` et flux <consumes>

#stable

Chaque entrée déclare une dépendance et le flux réseau correspondant.

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`name`], [chaîne], [unique dans le service (#code("E012"))],
  [`capability`], [chaîne], [dépendance résolue vers un provider de cette
    capacité],
  [`service`], [chaîne], [dépendance vers un service nommé de la stack],
  [`inject`], [table → gabarit], [variables construites à partir des
    `provides` consommés],
  [`mode`], [`request` (défaut) · `push`], [#experimental ; `push` : le
    consommé émet, le consommateur reçoit. Obligatoire à travers une diode
    (@frontieres)],
)

- Exactement un de `capability` et `service` (#code("E013")).
- Il existe au plus un provider pour une `capability`, sauf surcharge par la
  stack (#code("E023")).

#regle[
  *Treillis.* Ouvrir une connexion vers un service revient à le lire.
  L'étiquette de la zone du consommé #doit donc être inférieure ou égale à
  celle de la zone du consommateur (@treillis). Dans le cas contraire, le flux
  est une lecture vers le haut, refusée (#code("E040")). Aucun champ ne permet
  de déroger à cette règle.
]

- Seuls les flux déclarés sont ouverts, vers les seuls ports déclarés du
  consommé. Tout autre trafic entre zones est refusé ; le filtrage est avec
  état.
- Si les deux zones diffèrent et que l'une d'elles a une frontière `diode`
  (@frontieres), le flux ne peut pas être une requête (#code("E041")).

Capacités normalisées en 1.1 : `database`, `cache`, `queue`,
`object-storage`, `search`, `identity`. Un provider #peut en déclarer
d'autres.

Clés `provides` normalisées pour `object-storage` : `endpoint`, `region`,
`bucket`, `access_key`, `secret_key`. Le provider crée un seau et une clé
par consommateur ; chaque clé n'a de droits que sur son seau.

== `security` <security>

#stable

```yaml
security:
  zone: rh
  route_labels:
    - route: /health
      public: true
    - route: /employees/salaries
      methods: [GET]
      classification: internal
      categories: [rh]
      required_clearance: [comptable, admin]
```

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`zone`], [chaîne], [nom d'une zone définie par les patrons de la stack
    (@treillis), sinon #code("E042"). Sans patron : zones intégrées
    `public` < `default` < `internal` < `secure`],
  [`route_labels`], [liste], [règles d'autorisation par route, vérifiées en
    bordure],
)

Une étiquette de route :

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`route`], [chaîne], [chemin ; `*` en fin de segment couvre tout suffixe
    (`/salary/*`). Pas d'autre joker],
  [`methods`], [liste], [méthodes HTTP ; absent = toutes],
  [`public`], [booléen], [`true` : aucun jeton exigé. Exclusif avec les trois
    champs suivants (#code("E043"))],
  [`classification`], [niveau], [le niveau d'habilitation du sujet #doit
    être supérieur ou égal (pas de lecture vers le haut)],
  [`categories`], [liste], [le sujet #doit les détenir toutes (besoin d'en
    connaître)],
  [`required_clearance`], [liste de rôles], [le sujet #doit en détenir au
    moins un],
)

*Sémantique.* Une requête vers `route` est autorisée si et seulement si le
jeton présenté établit, pour le sujet :

#align(center)[
  niveau ≥ `classification` #h(4pt) *et* #h(4pt) `categories` ⊆ catégories
  du sujet #h(4pt) *et* #h(4pt) (`required_clearance` vide *ou* un rôle du
  sujet ∈ `required_clearance`).
]

Dès qu'un service déclare une étiquette, les routes qu'aucune étiquette ne
couvre sont refusées. Si plusieurs étiquettes couvrent une
route, la plus spécifique s'applique : préfixe le plus long, puis méthodes
explicites.

*Cohérence avec la zone.* La classification d'une route #doit-pas dépasser
le niveau de la zone du service, et ses catégories #doit être incluses dans
celles de la zone (#code("E044")). Un service ne peut donc pas servir de
données plus sensibles que sa zone.

*Mise en œuvre.* Le provider Biscuit traduit ces étiquettes en règles
Datalog : une comparaison d'entiers pour le niveau, une vérification par
catégorie et une jointure pour les rôles. La vérification a lieu en bordure,
dans Sozu, avant que la requête n'atteigne le service. Il revient au provider
d'établir que cette traduction est correcte, c'est-à-dire qu'elle accepte
exactement les accès permis par le treillis.

#note[
  *Compatibilité 1.0.* `required_clearance` y était obligatoire et seul. Un
  manifeste `1.0` garde sa sémantique : des rôles en disjonction, sans niveau
  ni catégorie.
]

== Ressources, échelle et sondes <sondes>

#stable

#tableau((auto, 1fr, 1fr),
  [Bloc], [Champs], [Règles],
  [`resources`], [`memory_request`, `memory_limit` (`Ki`, `Mi`, `Gi`, `Ti`) ;
    `cpu_request`, `cpu_limit` (cœurs, ou millicœurs `500m`)],
    [requête ≤ limite (#code("E014")) ; unité inconnue #code("E015")],
  [`autoscaling`], [`min_replicas`, `max_replicas`, `cpu_threshold`,
    `memory_threshold` (en %)], [`1 ≤ min ≤ max` (#code("E016")) ; le
    dimensionnement retient `max_replicas`],
  [`health_check`], [`path`, `interval`, `timeout`, `retries` (secondes,
    entiers > 0)], [`timeout < interval`, sinon #code("W011")],
  [`readiness`], [`command` (liste), `interval`, `timeout`], [commande
    exécutée dans le provider ; gabarits `{input.*}` admis],
  [`metrics`], [`provider` (`prometheus`), `path`, `port`], [],
  [`logging`], [`format` (`json` · `text`), `level`], [],
)

== `ports` <ports>

#stable

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`container`], [entier 1–65535], [port écouté par le service],
  [`protocol`], [`tcp` · `udp`], [défaut `tcp`],
  [`host`], [entier], [#deprecie (#code("W002")) : la publication passe par
    `exposure` ; un port d'hôte épingle le service à une machine],
)

== `storage` et `backup` <storage>

#experimental

#regle[
  *Stockage objet par défaut.* Les fichiers, pièces jointes et artefacts d'un
  service #devrait être placés dans un stockage objet, consommé par
  `consumes: - capability: object-storage` (@consumes). Un service sans état
  local peut être déplacé sans contrainte. `storage` décrit uniquement les
  données qui doivent rester sur un système de fichiers.
]

```yaml
storage:
  - name: repositories
    mount: /data/git
    class: local
    size: 50Gi
    rebuild: from-backup
  - name: tmp
    mount: /tmp/work
    class: ephemeral
backup:
  schedule: "*/30 * * * *"
  retention: { hourly: 24, daily: 7, weekly: 4, monthly: 12 }
  consistency:
    pre: ["forgejo", "dump", "--type", "tar"]
  verify: restore-test
```

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`name`], [unique dans le service (#code("E012"))],
  [`mount`], [chemin absolu (#code("E031"))],
  [`class`], [`ephemeral` : perdu au redémarrage ; `local` : stocké sur le
    nœud, perdu avec lui ; `replicated` : le service réplique lui-même ses
    données entre ses répliques, comme PostgreSQL sous Patroni],
  [`size`], [quantité ; obligatoire hors `ephemeral` (#code("E032"))],
  [`rebuild`], [pour `local` : `from-backup` · `from-object` · `from-replica`
    · `none`. Indique comment reconstruire le volume sur un autre nœud. Avec
    `none`, le service n'est pas relocalisable : le planner ne le déplace pas
    et le signale],
  [`backup.schedule`], [expression cron],
  [`backup.retention`], [nombre d'instantanés conservés par période],
  [`backup.consistency`], [`pre` / `post` : commandes exécutées dans le
    service autour de l'instantané],
  [`backup.verify`], [`none` · `restore-test` : restauration vérifiée à
    chaque cycle],
)

Un volume `local` sans `backup` ni `rebuild` est refusé (#code("E033")) : le
sort de ses données en cas de perte du nœud doit être déclaré.

== `secrets` <secrets>

#experimental

```yaml
secrets:
  - name: smtp_password
    ref: "openbao:kv/mail/smtp#password"
  - name: session_key
    generate: { kind: alnum, length: 64 }
    rotate: 90d
environment:
  SMTP_PASSWORD: "{secret.smtp_password}"
```

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`name`], [unique dans le service ; référencé par `{secret.<name>}`],
  [`ref`], [URI `<backend>:<chemin>[#<clé>]` d'un secret existant. Backends
    en 1.1 : `openbao`, `sops`],
  [`generate`], [secret créé par Hamac au premier déploiement, stocké dans le
    backend par défaut],
  [`rotate`], [durée (`d`, `h`) ; absent = pas de rotation automatique],
  [`as`], [`env` (défaut) · `file` : monté en lecture seule sous
    `/run/secrets/<name>`],
)

- Exactement un de `ref` et `generate` (#code("E034")).
- `{secret.x}` sans déclaration correspondante : #code("E020").
- Une valeur d'`environment` qui a l'apparence d'un secret littéral (clé en
  `*_PASSWORD`, `*_TOKEN`, `*_SECRET`, `*_KEY`, sans gabarit) produit
  #code("W012").

== `placement` <placement>

#experimental

```yaml
placement:
  needs: [public-ipv4, ssd]
  assurance:
    boot: measured-tpm2
    physical: site
  spread: failure_domain
```

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`needs`], [capacités que le nœud #doit offrir, telles que l'inventaire
    les déclare],
  [`assurance`], [minimum par axe (@assurance), qui s'ajoute à l'exigence de
    la zone],
  [`spread`], [`none` · `host` · `failure_domain` : répartition des
    répliques],
  [`affinity`, `anti_affinity`], [noms de services à rapprocher ou à
    séparer],
)

Le format ne prévoit pas de placement par nom d'hôte.

== `exposure` <exposure>

#experimental

Publie un port du service en bordure. Sans flux déclaré, c'est la seule
façon de rendre un service joignable depuis l'extérieur de sa zone.

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`hostname`], [nom DNS public],
  [`path_prefix`], [défaut `/`],
  [`port`], [un port de `ports` (#code("E035"))],
  [`protocol`], [`http` (défaut) · `tcp`],
  [`tls`], [`acme` · `internal` · `passthrough`],
)

Un service exposé en `http` qui porte des `route_labels` voit chaque requête
validée par la bordure selon @security.

= `kind: pattern` : patrons et contraintes <pattern>

Un #terme[patron] est une liste de contraintes sur la topologie. La topologie
que Hamac calcule pour une stack #doit satisfaire toutes les contraintes dures
de ses patrons. Les choix propres à une organisation (niveaux, zones,
exigences de stockage et d'assurance) sont définis dans des patrons ; Hamac
n'en fixe aucun. Des organisations aux besoins très différents utilisent donc
le même outil avec des patrons différents.

```yaml
manifest_version: "1.1"
kind: pattern
name: anssi-renforce
version: "1.0.0"
extends: [anssi-hygiene]

lattice:
  levels: [public, default, internal, secure]
  categories: [finance, rh, evaluation]

zones:
  - name: public
    level: public
  - name: default
    level: default
  - name: internal
    level: internal
  - name: rh
    level: internal
    categories: [rh]
  - name: secure
    level: secure
    boundary: diode

assurance:
  internal: { boot: confidential-vm, operator: secnumcloud }
  secure:   { boot: measured-tpm2, physical: site }

constraints:
  - id: one-level-per-host
    description: "Deux niveaux ne partagent jamais un noyau"
    expr: "forall h in hosts: count(levels_on(h)) <= 1"
  - id: stateful-quorum
    description: "Un service à état survit à la perte d'un domaine de panne"
    expr: >
      forall s in services where stateful(s):
        count(failure_domains(hosts_of(s))) >= 3

objectives:
  - minimize: count(hosts_used)
    priority: 1
  - minimize: moves
    priority: 2
```

== Champs

#tableau((auto, 1fr, 2fr),
  [Champ], [Stabilité], [Règle],
  [`version`], stable, [version sémantique du patron, distincte de
    `manifest_version`],
  [`extends`], stable, [patrons dont on hérite ; l'union des contraintes
    s'applique],
  [`lattice`], stable, [@treillis],
  [`zones`], stable, [@treillis],
  [`assurance`], experimental, [minimum d'assurance par zone (@assurance)],
  [`constraints`], experimental, [@contraintes],
  [`objectives`], experimental, [@objectifs],
)

== Treillis et zones <treillis>

#stable

- `lattice.levels` : les niveaux, du moins au plus sensible ; ordre total.
- `lattice.categories` : les catégories de besoin d'en connaître.
- Une #terme[étiquette] est un couple (niveau, ensemble de catégories), et
  (n#sub[1], C#sub[1]) ≤ (n#sub[2], C#sub[2]) si et seulement si
  n#sub[1] ≤ n#sub[2] et C#sub[1] ⊆ C#sub[2]. Cet ordre définit un treillis,
  celui du modèle Bell-LaPadula avec compartiments.
- Une #terme[zone] a un nom, une étiquette (`level`, et `categories` incluses
  dans `lattice.categories`) et, optionnellement, une frontière
  (`boundary`, @frontieres).
- Un flux du consommateur _c_ vers le consommé _s_ est permis si et seulement
  si étiquette(zone(_s_)) ≤ étiquette(zone(_c_)) (@consumes).

*Composition.* Quand une stack utilise plusieurs patrons, leurs treillis
#doit être identiques, ou l'un #doit étendre l'autre : mêmes niveaux dans le
même ordre, et catégories incluses. Sinon, #code("E050"). Une même zone
définie deux fois avec des étiquettes différentes produit #code("E051").

*Sans patron,* une stack utilise le patron intégré `hamac-default` : niveaux et
zones `public` < `default` < `internal` < `secure`, sans catégorie ni
contrainte. Cette sémantique est celle de la version 1.0.

== Frontières de zone <frontieres>

#tableau((auto, 1fr),
  [`boundary`], [Sens],
  [`firewall` (défaut)], [filtrage avec état ; les flux déclarés ouvrent des
    connexions],
  [`diode`], [passerelle unidirectionnelle, du bas vers le haut : aucune
    donnée ne sort de la zone vers une zone moins sensible],
)

À travers une diode, aucune requête ne peut recevoir de réponse. Un
`consumes` d'un service de la zone haute vers un service de la zone basse
#doit donc déclarer `mode: push` : le service consommé émet ce que le
consommateur reçoit (réplication, flux d'événements, fichiers). Un `consumes`
de mode `request` qui traverse une diode est refusé (#code("E041")).

Une zone derrière une diode a son propre plan de contrôle, puisqu'un
contrôleur extérieur n'en recevrait pas les rapports. Hamac produit une
infrastructure par enclave. Les manifestes signés entrent par la diode ;
l'état de l'enclave n'en sort que par une déclassification explicite.

== Axes d'assurance <assurance>

#experimental

Trois axes à valeurs ordonnées, fixés par le format en 1.1 :

#tableau((auto, 1fr),
  [Axe], [Valeurs, de la plus faible à la plus forte],
  [`boot`], [`none` < `provider-vtpm` < `confidential-vm` < `measured-tpm2`],
  [`operator`], [`any` < `eu` < `secnumcloud` < `self`],
  [`physical`], [`third-party` < `dedicated-rack` < `site`],
)

Un nœud offre une valeur par axe, déclarée par l'inventaire et constatée par
`hamac verify`. Une zone ou un service exige un minimum. Un placement est
admissible si et seulement si l'offre est au moins égale à l'exigence sur
chaque axe. Le bloc `assurance` d'un patron associe à un nom de zone
l'exigence de cette zone ; un axe absent n'impose rien.

#note[
  `provider-vtpm` et `confidential-vm` se distinguent sur un point : dans une
  VM classique, c'est l'hyperviseur du fournisseur qui mesure le démarrage ;
  dans une VM confidentielle (AMD SEV-SNP, Intel TDX), le processeur l'atteste
  et la mesure est opposable à l'hyperviseur.
]

== Contraintes <contraintes>

#experimental

Une contrainte a un `id` unique dans le patron, une `description`, une
`severity` (`hard` par défaut, ou `soft`), un `weight` pour les contraintes
`soft`, et une expression `expr` écrite dans le langage ci-dessous.

*Modèle.* Une expression porte sur une topologie candidate : les ensembles
finis `services`, `zones`, `hosts`, `flows`, `volumes`, et les fonctions qui
les relient. Hamac instancie les quantificateurs sur le parc et la stack,
puis confie le problème à un solveur. Un vérificateur indépendant contrôle
chaque solution avant qu'elle soit retenue ; la correction du résultat ne
dépend donc pas de celle du solveur.

*Grammaire.*

```
expr     ::= quant | impl
quant    ::= ("forall" | "exists") IDENT "in" set ["where" expr] ":" expr
impl     ::= disj ["=>" expr]
disj     ::= conj { "or" conj }
conj     ::= neg { "and" neg }
neg      ::= "not" neg | cmp
cmp      ::= term [ relop term ]
relop    ::= "=" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "subset"
term     ::= prod { ("+" | "-") prod }
prod     ::= atom { "*" INT }
atom     ::= INT | QUANTITY | STRING | IDENT
           | IDENT "(" [ term { "," term } ] ")"
           | IDENT "." IDENT
           | "(" expr ")"
set      ::= DOMAIN | IDENT "(" term ")"
DOMAIN   ::= "services" | "zones" | "hosts" | "flows" | "volumes"
QUANTITY ::= INT ("Ki" | "Mi" | "Gi" | "Ti" | "m")
```

L'arithmétique est linéaire : un produit a toujours un facteur constant. Le
langage n'a ni récursion ni quantification sur des ensembles d'ensembles. Il
est donc décidable sur un domaine fini, et une contradiction peut être
expliquée par un ensemble minimal de contraintes en conflit.

*Fonctions de base.*

#tableau((auto, 1fr, 2fr),
  [Fonction], [Type], [Sens],
  [`zone(s)`], [service → zone], [zone du service],
  [`level(z)`], [zone → niveau], [niveau de la zone ; comparable par `<`,
    `<=`],
  [`categories(z)`], [zone → ensemble], [],
  [`hosts_of(s)`], [service → ensemble], [hôtes portant une réplique],
  [`levels_on(h)`], [hôte → ensemble], [niveaux des zones placées sur l'hôte],
  [`failure_domains(H)`], [ensemble → ensemble], [domaines de panne couverts],
  [`count(E)`], [ensemble → entier], [cardinal],
  [`sum(E, f)`], [ensemble, fonction → entier], [somme],
  [`stateful(s)`], [service → booléen], [possède un volume `local` ou
    `replicated`],
  [`src(f)`, `dst(f)`], [flux → service], [],
  [`h.boot`, `h.operator`, `h.physical`], [hôte → valeur d'axe], [assurance
    offerte],
  [`h.memory`, `h.cpu`], [hôte → quantité], [capacité],
  [`has(h, c)`], [hôte, capacité → booléen], [capacité offerte],
  [`hosts_used`], [ensemble], [hôtes portant au moins une réplique],
  [`moves`], [entier], [répliques déplacées par rapport à la topologie
    courante],
)

Un littéral chaîne (`"site"`, `"rh"`) désigne un nom : de niveau, de
catégorie, de valeur d'assurance, de capacité, de zone, de service ou
d'hôte ; il se compare à tout terme de ces sortes. Les noms de domaines
(`services`, `hosts`…) sont aussi des ensembles utilisables après `in`.

Une expression mal typée, une fonction inconnue ou un identifiant non lié :
#code("E052"), avec la position dans l'expression.

== Objectifs <objectifs>

#experimental

`objectives` est une liste de `minimize: <terme>` ou `maximize: <terme>`, avec
une `priority` (1 = la plus importante). L'optimisation est
lexicographique par priorité ; à priorité égale, les termes sont sommés
selon leur `weight`. Les contraintes `soft` entrent dans l'objectif comme des
pénalités pondérées.

== Résultat de la résolution

- *Satisfiable* : la topologie retenue est écrite dans un
  `kind: infrastructure` (@infrastructure), avec un certificat qui réunit les
  patrons, le parc, la solution et le verdict du vérificateur.
- *Insatisfiable* : Hamac rapporte un ensemble minimal de contraintes en
  conflit, chacune avec son patron, son `id` et les chemins YAML des
  déclarations concernées (#code("E060")). Quand c'est possible, il indique
  aussi les ressources à ajouter au parc pour lever le conflit.

= `kind: stack` <stack>

#stable

```yaml
manifest_version: "1.1"
kind: stack
name: si-exemple
patterns: [anssi-renforce]
accept_experimental: true
services:
  - ref: services/hr-api.yml
    replicas: 3
    consumes:
      - name: db
        provider: postgresql-ha
infrastructure: infra/si-exemple.infra.yml
```

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`patterns`], [noms des patrons appliqués (@pattern) ; absent :
    `hamac-default`. Un patron est cherché parmi les fichiers donnés à la
    commande, puis dans `./patterns/` et `~/.hamac/patterns/`, ainsi que
    ceux qu'il étend (#code("E021") s'il est introuvable)],
  [`accept_experimental`], [`true` supprime #code("W001") pour toute la
    stack, dès qu'elle est validée avec ses services],
  [`services[].ref`], [chemin d'un manifeste `service`, relatif à la stack
    (#code("E021") s'il est introuvable)],
  [`services[].replicas`], [surcharge de `replicas`],
  [`services[].consumes[]`], [force le provider (`provider` : nom d'un
    service-provider) d'un `consumes` nommé ; #code("E022") si le nom n'existe
    pas dans le service],
  [`infrastructure`], [chemin d'une infrastructure imposée ; absent =
    calculée],
)

= `kind: infrastructure` <infrastructure>

#stable

Un manifeste d'infrastructure est produit par le planner. Un opérateur peut
le relire, le figer ou le modifier ; une infrastructure modifiée est
revérifiée contre les patrons de la stack avant tout déploiement.

#tableau((auto, 1fr),
  [Champ], [Règle],
  [`backend`], [`physical` · `incus` · `qemu` · `kubernetes` ·
    `docker-compose`],
  [`minimum_requirements`], [`nodes`, `total_ram`, `total_cpu`],
  [`proposed_topology.nodes[]`], [`role`, `count`, `ram`, `cpu`, `boot`,
    `os` (`image`, `sha256`), `isolated`, `provisioning_profile`],
  [`proposed_topology.network.segments[]`], [`name`, `cidr`, `vlan`],
  [`proposed_topology.network.firewall[]`], [règles textuelles
    `ALLOW|DENY <zone> -> <zone> [(détail)]` ; un détail `a -> b` désigne le
    flux déclaré qui justifie la règle],
  [`warnings`], [liste de chaînes],
  [`certificate`], [#experimental ; référence au certificat de résolution],
)

Chaque règle `ALLOW` #doit indiquer le flux déclaré qui la justifie
(#code("E045"), vérifié sur le manifeste seul).

= `kind: provisioning_profile` <provisioning-profile>

#stable

Un profil de provisioning décrit le système installé sur une machine : une
image d'OS et une liste de bundles paramétrés. Il est indépendant des machines
qui l'utilisent ; un nœud d'infrastructure le désigne par son nom
(`proposed_topology.nodes[].provisioning_profile`, @infrastructure). La
spécification du provisioning (`doc/typst/provisioning-spec.typ`) décrit
comment Hamac l'applique : démarrage PXE, rendu et fusion du cloud-init,
écriture de l'image sur le disque.

```yaml
manifest_version: "1.1"
kind: provisioning_profile
name: dev-workstation

os:
  image: debian-13-amd64
  url: https://cdimage.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2
  sha256: "…"
  format: qcow2
  family: debian

bundles:
  - name: dev-workstation
    params:
      username: devuser
      timezone: Europe/Paris

cloud_init_extra:
  runcmd:
    - echo "Provisioned by Hamac" > /etc/motd
```

#tableau((auto, 1fr, auto, 2fr),
  [Champ], [Type], [Requis], [Règle],
  [`os`], [objet], [oui], [image d'OS, voir ci-dessous],
  [`bundles`], [liste], [non], [bundles appliqués dans l'ordre de la liste ;
    chacun a un `name` (nom d'un `kind: bundle`) et des `params`, transmis
    tels quels au gabarit du bundle. Un bundle listé deux fois : #code("E012")],
  [`cloud_init_extra`], [objet], [non], [fragment cloud-init fusionné après
    ceux des bundles],
  [`assurance`], [objet, @assurance], [non], [#experimental ; niveaux
    d'assurance que garantit une machine installée par ce profil],
)

Un profil sans bundle ni `cloud_init_extra` ne change rien à l'image
installée : #code("W013").

== Bloc `os`

#tableau((auto, 1fr, auto, 2fr),
  [Champ], [Type], [Requis], [Règle],
  [`image`], [chaîne], [oui], [identifiant de l'image, à usage humain],
  [`url`], [chaîne], [oui], [URL de l'image de référence, consommée telle
    quelle par les VM],
  [`sha256`], [64 caractères hexadécimaux], [oui], [empreinte de l'image
    (#code("E011"))],
  [`format`], [`qcow2` · `raw` · `iso` · `netinstall`], [oui], [`netinstall` :
    noyau et initrd d'installation, suivis d'une installation automatisée],
  [`family`], [chaîne], [non], [famille d'OS (`debian` par défaut) ; choisit
    la variante du gabarit cloud-init des bundles],
  [`raw_zst_url`], [chaîne], [non], [image disque brute compressée en zstd,
    dérivée de `url`, pour l'écriture sur une machine physique],
  [`raw_zst_sha256`], [chaîne], [non], [empreinte de `raw_zst_url`],
  [`bmap_url`], [chaîne], [non], [carte des blocs utiles (`bmaptool create`)
    associée à `raw_zst_url`],
)

= `kind: bundle` <bundle>

#stable

Un bundle est une brique réutilisable d'un profil : un répertoire
`templates/bundles/<name>/` qui contient le manifeste `bundle.yaml` et un
gabarit Jinja2 de fragment cloud-init.

```
templates/bundles/dev-workstation/
├── bundle.yaml
├── cloud-init.yaml.j2           # gabarit par défaut
└── cloud-init.<family>.yaml.j2  # variante pour une famille d'OS (optionnel)
```

```yaml
manifest_version: "1.1"
kind: bundle
name: dev-workstation
version: "0.1.0"
description: "Poste de développement : utilisateur, SSH, Docker"
params:
  username:
    type: string
    required: true
  ssh_public_keys:
    type: list[string]
depends_on: []
```

#tableau((auto, 1fr, 2fr),
  [Champ], [Type], [Règle],
  [`version`], [chaîne], [version du bundle ; `0.1.0` par défaut],
  [`description`], [chaîne], [],
  [`params`], [table nom → spécification], [paramètres acceptés : `type`
    (`string`, `int`, `bool`, `list[string]`, `list[int]`, `object` ; autre
    valeur : #code("E007")) et `required` (booléen, `false` par défaut)],
  [`depends_on`], [liste de noms], [bundles à appliquer avant celui-ci],
  [`lifecycle`], [`install` · `converge`], [#experimental ; voir ci-dessous],
)

Le gabarit reçoit les valeurs des `params` données par le profil. Pour une
famille d'OS donnée, Hamac prend `cloud-init.<family>.yaml.j2` s'il existe,
sinon `cloud-init.yaml.j2`. La fusion des fragments de plusieurs bundles est
décrite dans la spécification du provisioning.

*Cycle de vie* #experimental. `lifecycle: install` (défaut) : le bundle est
appliqué une fois, au premier démarrage. `lifecycle: converge` : il est
appliqué à l'installation, puis en cours de vie par l'agent. Un bundle
`converge` #doit décrire un état à atteindre ; il est appliqué de façon
idempotente, et tout écart constaté est signalé comme une dérive. Ce mode
permet de prendre en charge une machine que Hamac n'a pas installée.

= Validation <validation>

== Trois étages

+ *Syntaxe et types*, sur un manifeste seul : YAML valide, champs connus,
  types, formats, cohérence interne. Commande : `hamac validate <fichiers…>`.
+ *Références*, sur un ensemble de manifestes : `ref` résolus, patrons
  composés, providers trouvés, gabarits liés, zones définies.
+ *Sémantique*, sur la stack et ses patrons, puis sur le parc : treillis,
  flux, cohérence des étiquettes, contraintes des patrons.

`hamac validate` applique les étages 2 et 3 dès qu'une stack figure parmi
les fichiers donnés : la stack, ses services, ses patrons et les providers
trouvés forment l'ensemble vérifié. `hamac plan` traite toujours les fichiers
donnés comme une stack, implicite si aucune n'est fournie, avant de calculer
la topologie.

Chaque diagnostic donne un code, le fichier, le chemin YAML
(`security.route_labels.1.classification`) et un message. Une erreur (`E…`)
fait échouer la commande ; un avertissement (`W…`) ne la fait échouer qu'avec
`--strict`.

== Catalogue

Chaque code est couvert par un cas de `tests/hamac/catalogue.t/cases/`,
dont le nom commence par le code. Le validateur #doit tous les refuser (avec
`--strict` pour les avertissements) en émettant ce code, et #doit accepter
les exemples d'`examples/` ; la suite de tests et la CI le vérifient.

#tableau((auto, auto, 1fr),
  [Code], [Étage], [Condition],
  code("E001"), [1], [YAML invalide, ou racine qui n'est pas un objet],
  code("E002"), [1], [`manifest_version` absent, mal formé ou non supporté],
  code("E003"), [1], [champ inconnu ou réservé],
  code("E004"), [1], [`name` qui n'est pas un nom DNS],
  code("E005"), [1], [`kind` inconnu],
  code("E006"), [1], [champ obligatoire absent],
  code("E007"), [1], [type incorrect],
  code("E010"), [2], [deux manifestes de même `kind` et même `name` dans une
    stack],
  code("E011"), [1], [`sha256` qui n'est pas 64 caractères hexadécimaux],
  code("E012"), [1], [nom dupliqué dans une liste (`consumes`, `storage`,
    `secrets`)],
  code("E013"), [1], [`consumes` sans, ou avec à la fois, `capability` et
    `service`],
  code("E014"), [1], [requête de ressource supérieure à sa limite],
  code("E015"), [1], [quantité ou unité invalide],
  code("E016"), [1], [`autoscaling` incohérent, ou `replicas < 1`],
  code("E020"), [1–2], [gabarit invalide, ou référence non liée : secret
    non déclaré (1), clé absente des `provides`, service hors de la stack (2)],
  code("E021"), [2], [`ref` de stack introuvable],
  code("E022"), [2], [surcharge de `consumes` sans entrée correspondante],
  code("E023"), [2], [aucun provider pour une `capability`, ou plusieurs sans
    surcharge],
  code("E030"), [1], [`volumes` et `storage` dans le même service],
  code("E031"), [1], [`mount` non absolu],
  code("E032"), [1], [`size` absent pour un volume persistant],
  code("E033"), [1], [volume `local` sans `backup` ni `rebuild`],
  code("E034"), [1], [secret sans, ou avec à la fois, `ref` et `generate`],
  code("E035"), [1], [`exposure.port` absent de `ports`],
  code("E040"), [3], [flux qui lit vers le haut],
  code("E041"), [3], [flux de mode `request` à travers une diode],
  code("E042"), [2], [zone inconnue des patrons de la stack],
  code("E043"), [1], [étiquette de route `public` combinée à une exigence],
  code("E044"), [3], [étiquette de route au-dessus de la zone du service],
  code("E045"), [1], [règle `ALLOW` sans flux justificatif],
  code("E050"), [2], [treillis de patrons incompatibles],
  code("E051"), [2], [zone définie deux fois avec des étiquettes
    différentes],
  code("E052"), [1], [expression de contrainte mal formée ou mal typée],
  code("E060"), [3], [contraintes insatisfiables, avec explication ; émis par
    le solveur du planner, qui n'est pas encore livré ; ce code n'a donc pas de
    cas en 1.1],
  code("W001"), [1], [champ expérimental sans `accept_experimental`],
  code("W002"), [1], [forme dépréciée, avec son remplaçant],
  code("W010"), [1], [image OCI non épinglée par empreinte],
  code("W011"), [1], [`health_check.timeout ≥ interval`],
  code("W012"), [1], [valeur d'environnement qui ressemble à un secret
    littéral],
  code("W013"), [1], [profil de provisioning sans bundle ni
    `cloud_init_extra`],
)

== Schéma JSON

Un schéma JSON (draft 2020-12) est publié pour chaque version du format :
`doc/schema/hamac-manifest-1.1.schema.json`. Il couvre le premier étage, ce
qui suffit aux éditeurs et aux générateurs tiers pour valider et compléter un
manifeste ; les étages 2 et 3 restent du ressort de `hamac validate` et
`hamac plan`. En cas de divergence, ce document fait foi.

= Historique

#tableau((auto, auto, 1fr),
  [Version], [Date], [Changements],
  [1.0], [2025], [`service`, `stack`, `infrastructure` ;
    `provisioning_profile` et `bundle` (spécification du provisioning v0.1).
    Spécification implicite, portée par le code et les exemples],
  [1.1], [2026-10], [première spécification écrite ; versionnement et
    stabilité ; refus des champs inconnus ; noms DNS ; `security` étendu
    (niveaux, catégories, rôles, routes publiques) ; `kind: pattern`
    (treillis, zones, diodes, assurance, contraintes, objectifs) ;
    `storage`, `backup`, `secrets`, `placement`, `exposure` expérimentaux ;
    `volumes` et `ports[].host` dépréciés ; `provisioning_profile` et
    `bundle` décrits ici, champs `assurance` et `lifecycle` ; catalogue des
    erreurs],
)
