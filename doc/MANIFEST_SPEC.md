# Hamac — spécification du format de manifeste

> **Version du format : 1.1** — *brouillon du 2026-10-19.*
>
> Ce document est la référence du format pivot `hamac-manifest`. Il est
> indépendant de Sieste : tout outil capable d'émettre un manifeste conforme
> pilote Hamac. Il remplace la description implicite que portaient jusqu'ici
> le code (`pkgs/hamac-provisioning/manifest_types.ml`) et les exemples.
>
> Le provisioning bare-metal (`kind: provisioning_profile`, `kind: bundle`)
> est détaillé dans [`PROVISIONING_SPEC.md`](PROVISIONING_SPEC.md) ; ce
> document n'en reprend que l'enveloppe commune et les règles nouvelles.

## Sommaire

1. Principes
2. Versionnement et stabilité
3. Enveloppe commune
4. Gabarits
5. `kind: service`
6. `kind: pattern` — patrons et langage de contraintes
7. `kind: stack`
8. `kind: infrastructure`
9. `kind: provisioning_profile` et `kind: bundle`
10. Validation : règles et catalogue des erreurs
11. Schéma JSON
12. Historique

---

## 1. Principes

1. **L'infrastructure est inférée, pas déclarée.** Un service déclare ce
   dont il a besoin (ressources, dépendances, sensibilité, stockage) ;
   Hamac calcule la topologie qui le satisfait. Aucun manifeste de service
   ne nomme une machine.
2. **Six `kind`, plusieurs auteurs.** Le développeur écrit `service` ;
   l'opérateur écrit `stack` et choisit des `pattern` ; le responsable de la
   sécurité écrit ou adopte les `pattern` ; le planner produit
   `infrastructure` ; l'administrateur du parc écrit `provisioning_profile`
   et `bundle`.
3. **Références, jamais valeurs, pour les secrets.** Aucun champ du format
   ne porte un secret en clair.
4. **Refuser plutôt que deviner.** Un champ inconnu, une référence
   pendante, un flux qui viole le treillis : le manifeste est refusé, avec le
   chemin YAML de l'erreur et son identifiant (§10).
5. **Le format est public et stable.** Une fois un champ déclaré *stable*,
   sa sémantique ne change plus dans la même version majeure (§2).

Les mots **DOIT**, **NE DOIT PAS**, **DEVRAIT** et **PEUT** ont le sens des
RFC 2119 et 8174.

---

## 2. Versionnement et stabilité

### 2.1 `manifest_version`

Chaque manifeste porte `manifest_version: "<majeure>.<mineure>"`.

- Une **version mineure** n'ajoute que des champs optionnels, des valeurs
  d'énumération ou des `kind`. Un manifeste valide en `1.0` reste valide en
  `1.1`, avec la même sémantique.
- Une **version majeure** peut retirer ou changer un champ. Elle s'accompagne
  d'un outil de migration (`hamac migrate`).
- Un outil qui implémente la version `M.m` :
  - DOIT accepter tout manifeste `M.k` avec `k ≤ m` ;
  - DOIT refuser un manifeste `M.k` avec `k > m` (**E002**), en indiquant la
    version qu'il implémente : il ne peut pas savoir ce que signifient des
    champs plus récents ;
  - DOIT refuser une version majeure différente (**E002**).

### 2.2 Niveaux de stabilité

Chaque champ de ce document porte l'un de ces niveaux :

| Niveau | Garantie |
|---|---|
| **stable** | sémantique figée pour toute la version majeure |
| **expérimental** | peut changer dans une version mineure ; son usage produit un avertissement **W001**, sauf si la stack déclare `accept_experimental: true` |
| **déprécié** | accepté, avertissement **W002** avec le remplaçant ; retiré à la majeure suivante |

En 1.1, sont **expérimentaux** : `storage`, `placement`, `secrets`,
`exposure`, `backup`, les contraintes et objectifs de `kind: pattern`, et le
cycle de vie `converge` des bundles. Le reste est **stable**.

### 2.3 Champs inconnus et extensions

- Un champ inconnu à un emplacement défini par ce document est une
  **erreur** (**E003**). C'est ce qui attrape les fautes de frappe
  (`replica: 3`).
- Les champs dont le nom commence par `x-` sont des **extensions** : ils
  sont ignorés par Hamac, conservés tels quels, et PEUVENT apparaître à tout
  niveau d'objet. Un générateur tiers y range ce qui lui est propre.
- `metadata.annotations` (§3) est l'autre réceptacle libre.

---

## 3. Enveloppe commune — *stable*

```yaml
manifest_version: "1.1"
kind: service            # service | pattern | stack | infrastructure
                         # | provisioning_profile | bundle
name: hr-api
metadata:                # optionnel
  description: "API des ressources humaines"
  labels:                # clés/valeurs courtes, utilisables par les sélecteurs
    team: rh
  annotations:           # texte libre, ignoré par Hamac
    sieste.ocamlpro.com/source: "hr/api.zzz"
```

| Champ | Type | Obligatoire | Règle |
|---|---|---|---|
| `manifest_version` | chaîne `M.m` | oui | §2.1 |
| `kind` | énumération | oui en 1.1 | en `1.0`, l'absence de `kind` vaut `service` (déprécié, **W002**) |
| `name` | chaîne | oui | **nom DNS** : `^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$` (**E004**). Les manifestes `1.0` acceptent aussi `_`, avec **W002** : un nom de service devient un nom d'hôte, et `_` n'y est pas admis |
| `metadata.description` | chaîne | non | |
| `metadata.labels` | table chaîne → chaîne | non | clés `^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?$` |
| `metadata.annotations` | table chaîne → chaîne | non | |
| `signature` | objet | non | **réservé** à la signature des manifestes (version ultérieure) ; refusé s'il est présent en 1.1 (**E003**) |

Les noms sont uniques par `kind` au sein d'une stack (**E010**).

---

## 4. Gabarits — *stable*

Certaines chaînes sont des **gabarits** : des segments `{expression}` y sont
remplacés à la résolution. `{{` et `}}` produisent des accolades littérales.

| Expression | Valeur | Où |
|---|---|---|
| `{generate.alpha(n)}` | `n` lettres minuscules tirées au hasard | `inputs` d'un provider |
| `{generate.alnum(n)}` | `n` caractères alphanumériques | `inputs` d'un provider |
| `{input.<clé>}` | valeur résolue d'un `inputs` du provider | `provides`, `environment`, `readiness` d'un provider |
| `{consumer.name}` | nom du service consommateur | `inputs` d'un provider |
| `{service_name}` | nom du service courant | partout dans un service |
| `{<clé>}` | valeur `provides.<clé>` du service consommé | `consumes[].inject` |
| `{secret.<nom>}` | référence à un secret déclaré (§5.9) | `environment`, `consumes[].inject` — *expérimental* |

- Le tirage aléatoire utilise le générateur cryptographique du système ;
  `--seed` le rend reproductible pour les tests.
- Une expression inconnue, ou une clé absente du `provides` consommé, est
  une erreur (**E020**).
- Une valeur `{secret.x}` n'est **jamais** écrite dans un fichier généré :
  elle est injectée au démarrage par l'agent (§5.9).

---

## 5. `kind: service`

Un service est une unité déployable. Un **provider** est un service qui
déclare une `capability` et des `provides` : il est consommé par d'autres
(base de données, cache, stockage objet…). Un provider est un manifeste, pas
un greffon : ajouter un provider ne demande pas de recompiler Hamac.

### 5.1 Vue d'ensemble

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
  zone: internal
  route_labels:
    - route: /health
      public: true
    - route: /employees/salaries
      classification: confidential
      categories: [finance]
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

### 5.2 Champs

| Champ | Type | Obligatoire | Stabilité | Sémantique |
|---|---|---|---|---|
| `runtime` | `http` \| `cli` \| `batch` \| `eventloop` \| `custom` | oui | stable | nature de la charge ; `http` active les sondes HTTP et l'exposition |
| `artifact` | objet (§5.3) | oui, sauf pour un provider abstrait | stable | ce qui s'exécute |
| `capability` | chaîne | non | stable | fait du service un provider de cette capacité |
| `inputs` | table chaîne → gabarit | non | stable | valeurs générées une fois par consommateur (provider) |
| `provides` | table chaîne → gabarit | non | stable | ce que le provider expose à ses consommateurs |
| `readiness` | objet (§5.6) | non | stable | commande de disponibilité d'un provider |
| `consumes` | liste (§5.4) | non | stable | dépendances, et **flux réseau déclarés** |
| `security` | objet (§5.5) | non | stable | zone et étiquettes d'autorisation ; absent ⇒ zone `default` |
| `ports` | liste (§5.7) | non | stable | ports écoutés |
| `environment` | table chaîne → gabarit | non | stable | variables d'environnement |
| `resources` | objet (§5.6) | non | stable | requêtes et limites |
| `replicas` | entier ≥ 1 | non (1) | stable | nombre d'instances |
| `autoscaling` | objet (§5.6) | non | stable | bornes de mise à l'échelle |
| `health_check` | objet (§5.6) | non | stable | sonde de santé |
| `metrics` | objet (§5.6) | non | stable | point de collecte |
| `logging` | objet (§5.6) | non | stable | format et niveau |
| `volumes` | liste | non | **déprécié** | chemin d'hôte ; remplacé par `storage` (**W002**). Interdit en 1.1 avec `storage` (**E030**) |
| `storage` | liste (§5.8) | non | expérimental | volumes de système de fichiers, par classe |
| `secrets` | liste (§5.9) | non | expérimental | références de secrets |
| `placement` | objet (§5.10) | non | expérimental | capacités et niveaux d'assurance requis |
| `exposure` | liste (§5.11) | non | expérimental | publication en bordure |
| `backup` | objet (§5.8) | non | expérimental | politique de sauvegarde |

### 5.3 `artifact` — *stable*

| Champ | Type | Règle |
|---|---|---|
| `path` | chaîne | chemin, URL, ou référence OCI ; une référence OCI DEVRAIT être épinglée par digest (`@sha256:…`), sinon **W010** |
| `sha256` | 64 caractères hexadécimaux | empreinte de l'artefact (**E011** si le format est faux) |
| `format` | `oci-image` \| `native-linux-amd64` \| `native-linux-arm64` \| `incus-vm-image` \| `incus-system-image` | détermine l'exécutant : conteneur, binaire natif, VM ou conteneur système |

Le format remplace toute notion séparée de « runtime d'exécution » : un
artefact `incus-vm-image` s'exécute dans une VM, un `oci-image` dans un
conteneur, sans autre déclaration.

### 5.4 `consumes` et flux — *stable*

Chaque entrée déclare une dépendance **et** le flux réseau qu'elle ouvre.

| Champ | Type | Règle |
|---|---|---|
| `name` | chaîne | unique dans le service (**E012**) |
| `capability` | chaîne | dépendance résolue vers **un** provider de cette capacité |
| `service` | chaîne | dépendance vers un service nommé de la stack |
| `inject` | table chaîne → gabarit | variables construites à partir des `provides` consommés |

- Exactement un de `capability` et `service` (**E013**).
- **Treillis** (D4) : le consommateur ouvre une connexion vers le consommé,
  donc le **lit**. Le niveau de la zone du consommé DOIT être inférieur ou
  égal à celui de la zone du consommateur, et ses catégories incluses
  (§6.2). Sinon le flux est une **lecture vers le haut**, refusée par
  `hamac plan` (**E040**). Aucune déclaration ne lève cette règle.
- Seuls les flux déclarés sont ouverts, vers les seuls ports déclarés du
  consommé. Tout autre trafic entre zones est refusé ; le filtrage est avec
  état.
- Si la frontière entre les deux zones est une **diode** (§6.3), le flux
  ne peut pas être une requête : voir §6.3 et **E041**.

Capacités normalisées en 1.1 : `database`, `cache`, `queue`,
`object-storage`, `search`, `identity`. Un provider PEUT en déclarer
d'autres.

Clés `provides` normalisées pour `object-storage` : `endpoint`, `region`,
`bucket`, `access_key`, `secret_key`. Le provider crée **un seau et une clé
par consommateur** ; la clé n'a de droits que sur ce seau.

### 5.5 `security` — *stable*

```yaml
security:
  zone: internal
  route_labels:
    - route: /health
      public: true
    - route: /employees/salaries
      methods: [GET]
      classification: confidential
      categories: [finance]
      required_clearance: [comptable, admin]
```

| Champ | Type | Règle |
|---|---|---|
| `zone` | chaîne | nom d'une zone définie par les patrons de la stack (§6.2) (**E042** sinon). Sans patron, les zones intégrées `public` < `default` < `internal` < `secure` |
| `route_labels` | liste | règles d'autorisation par route, validées **en bordure** |

Une étiquette de route :

| Champ | Type | Règle |
|---|---|---|
| `route` | chaîne | chemin ; `*` en fin de segment couvre tout suffixe (`/salary/*`). Pas d'autre joker |
| `methods` | liste de méthodes HTTP | optionnel ; absent = toutes |
| `public` | booléen | `true` : aucun jeton exigé. Exclusif avec les trois champs suivants (**E043**) |
| `classification` | nom de niveau du treillis | le sujet DOIT avoir un niveau d'habilitation ≥ (Bell-LaPadula, pas de lecture vers le haut) |
| `categories` | liste de catégories | le sujet DOIT les détenir **toutes** (besoin d'en connaître) |
| `required_clearance` | liste de rôles | le sujet DOIT en détenir **au moins un** (disjonction) |

**Sémantique.** Une requête vers `route` est autorisée si et seulement si le
jeton présenté prouve, pour le sujet :
`niveau ≥ classification` **et** `categories ⊆ catégories du sujet` **et**
(`required_clearance` vide **ou** un rôle du sujet ∈ `required_clearance`).
Une route non couverte par une étiquette est **refusée** dès que le service
déclare au moins une étiquette (liste blanche). Si plusieurs étiquettes
couvrent une route, la plus spécifique (préfixe le plus long, puis méthodes
explicites) s'applique.

**Cohérence avec la zone.** La classification d'une route NE DOIT PAS
dépasser le niveau de la zone du service (**E044**) : un service ne détient
pas de donnée plus sensible que la zone où il s'exécute. Ses catégories
DOIVENT être incluses dans celles de la zone (**E044**).

**Projection.** Le provider Biscuit traduit ces étiquettes en règles Datalog
(comparaison d'entiers pour le niveau, un *check* par catégorie, jointure
pour la disjonction de rôles). La validation a lieu dans la bordure (Sozu),
avant que la requête n'atteigne le service. La correction de cette
traduction (tout accès permis par le treillis est accepté, tout accès
interdit est refusé) est une obligation de preuve du provider, pas du
format.

*Compatibilité 1.0* : `required_clearance` était obligatoire et seul. Un
manifeste `1.0` garde sa sémantique : rôles en disjonction, sans niveau ni
catégorie.

### 5.6 Ressources, échelle, sondes — *stable*

| Bloc | Champs | Règles |
|---|---|---|
| `resources` | `memory_request`, `memory_limit` (`Ki`, `Mi`, `Gi`, `Ti`), `cpu_request`, `cpu_limit` (cœurs, ou millicœurs `500m`) | requête ≤ limite (**E014**) ; unités inconnues **E015** |
| `autoscaling` | `min_replicas`, `max_replicas`, `cpu_threshold`, `memory_threshold` (en %) | `1 ≤ min ≤ max` (**E016**) ; le dimensionnement retient `max_replicas` |
| `health_check` | `path`, `interval`, `timeout`, `retries` (secondes, entiers > 0) | `timeout < interval` (**W011**) |
| `readiness` | `command` (liste), `interval`, `timeout` | commande exécutée dans le provider ; gabarits `{input.*}` admis |
| `metrics` | `provider` (`prometheus`), `path`, `port` | |
| `logging` | `format` (`json` \| `text`), `level` | |

### 5.7 `ports` — *stable*

| Champ | Type | Règle |
|---|---|---|
| `container` | entier 1–65535 | port écouté par le service |
| `protocol` | `tcp` \| `udp` | défaut `tcp` |
| `host` | entier | **déprécié** en 1.1 (**W002**) : la publication passe par `exposure` ; un port d'hôte épingle le service à une machine |

### 5.8 `storage` et `backup` — *expérimental*

**Règle de conception : S3 d'abord.** Les fichiers, pièces jointes et
artefacts d'un service DEVRAIENT aller dans un stockage objet, consommé par
`consumes: - capability: object-storage` (§5.4). Un service sans état local
se déplace librement. `storage` ne décrit que ce qui doit rester un système
de fichiers.

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

| Champ | Règle |
|---|---|
| `name` | unique dans le service (**E012**) |
| `mount` | chemin absolu (**E031**) |
| `class` | `ephemeral` (perdu au redémarrage), `local` (sur le nœud ; perdu si le nœud l'est), `replicated` (**le service réplique lui-même** ses données entre répliques, comme PostgreSQL sous Patroni) |
| `size` | quantité (`Gi`) ; obligatoire hors `ephemeral` (**E032**) |
| `rebuild` | pour `local` : `from-backup` \| `from-object` \| `from-replica` \| `none`. Dit comment reconstruire le volume sur un autre nœud. `none` déclare le service **non relocalisable** : le planner ne le déplacera pas, et le dit |
| `backup.schedule` | expression cron |
| `backup.retention` | nombres d'instantanés par période |
| `backup.consistency.pre` / `.post` | commandes exécutées dans le service autour de l'instantané |
| `backup.verify` | `none` \| `restore-test` : restauration vérifiée à chaque cycle |

Un volume `local` sans `backup` ni `rebuild` explicite est refusé (**E033**) :
une donnée dont la perte n'a pas été décidée ne doit pas pouvoir se perdre
par défaut.

### 5.9 `secrets` — *expérimental*

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

| Champ | Règle |
|---|---|
| `name` | unique dans le service ; référencé par `{secret.<name>}` |
| `ref` | URI `<backend>:<chemin>[#<clé>]` d'un secret existant. Backends en 1.1 : `openbao`, `sops` |
| `generate` | secret créé par Hamac au premier déploiement et stocké dans le backend par défaut |
| `rotate` | durée (`d`, `h`) ; absent = pas de rotation automatique |
| `as` | `env` (défaut) \| `file` (monté en lecture seule, chemin `/run/secrets/<name>`) |

- Exactement un de `ref` et `generate` (**E034**).
- `{secret.x}` sans déclaration correspondante : **E020**.
- Une valeur d'`environment` qui a l'apparence d'un secret littéral (clé en
  `*_PASSWORD`, `*_TOKEN`, `*_SECRET`, `*_KEY` sans gabarit) produit
  **W012**.

### 5.10 `placement` — *expérimental*

```yaml
placement:
  needs: [public-ipv4, ssd]
  assurance:
    boot: measured-tpm2
    physical: site
  spread: failure_domain
```

| Champ | Règle |
|---|---|
| `needs` | capacités que le nœud DOIT offrir (déclarées par l'inventaire) |
| `assurance` | minimum par axe (§6.4), **en plus** de ce qu'exige la zone |
| `spread` | `none` \| `host` \| `failure_domain` : répartition des répliques |
| `affinity` / `anti_affinity` | listes de noms de services à rapprocher ou à séparer |

Un service ne DOIT PAS nommer une machine. Une contrainte de placement par
nom d'hôte n'existe pas dans le format (§1).

### 5.11 `exposure` — *expérimental*

Publie un port du service en **bordure** : c'est le seul moyen d'être
joignable depuis l'extérieur de sa zone sans flux déclaré.

| Champ | Règle |
|---|---|
| `hostname` | nom DNS public |
| `path_prefix` | défaut `/` |
| `port` | un port de `ports` (**E035**) |
| `protocol` | `http` (défaut) \| `tcp` |
| `tls` | `acme` \| `internal` \| `passthrough` |

Un service exposé en `http` avec des `route_labels` voit chaque requête
validée par la bordure selon §5.5.

---

## 6. `kind: pattern` — patrons et langage de contraintes

Un **patron** est une liste de contraintes sur la topologie. La topologie
calculée par Hamac pour une stack DOIT satisfaire toutes les contraintes
dures de tous ses patrons. Les valeurs propres à une organisation (niveaux,
zones, exigences de stockage, d'assurance) vivent dans des patrons, jamais
dans Hamac.

```yaml
manifest_version: "1.1"
kind: pattern
name: anssi-renforce
version: "1.0.0"
extends: [anssi-hygiene]

lattice:                                  # stable
  levels: [public, default, internal, secure]
  categories: [finance, rh, evaluation]

zones:                                    # stable
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
    boundary: diode                       # §6.3

assurance:                                # expérimental
  internal: { boot: confidential-vm, operator: secnumcloud }
  secure:   { boot: measured-tpm2, physical: site }

constraints:                              # expérimental
  - id: one-level-per-host
    description: "Deux niveaux ne partagent jamais un noyau"
    expr: "forall h in hosts: count(levels_on(h)) <= 1"
  - id: stateful-quorum
    description: "Un service à état survit à la perte d'un domaine de panne"
    expr: >
      forall s in services where stateful(s):
        count(failure_domains(hosts_of(s))) >= 3

objectives:                               # expérimental
  - minimize: count(hosts_used)
    priority: 1
  - minimize: moves
    priority: 2
```

### 6.1 Champs

| Champ | Stabilité | Règle |
|---|---|---|
| `version` | stable | version sémantique du patron (distincte de `manifest_version`) |
| `extends` | stable | patrons dont on hérite ; l'union de leurs contraintes s'applique |
| `lattice` | stable | §6.2 |
| `zones` | stable | §6.2 |
| `assurance` | expérimental | minimum d'assurance par zone (§6.4) |
| `constraints` | expérimental | §6.5 |
| `objectives` | expérimental | §6.6 |

### 6.2 Treillis et zones — *stable*

- `lattice.levels` : niveaux, **du moins au plus sensible**. Ordre total.
- `lattice.categories` : catégories de besoin d'en connaître. Ensemble.
- Une **étiquette** est un couple (niveau, ensemble de catégories).
  `(n₁, C₁) ≤ (n₂, C₂)` ssi `n₁ ≤ n₂` et `C₁ ⊆ C₂`. C'est un treillis
  (Bell-LaPadula avec compartiments).
- Une **zone** a un nom, une étiquette (`level`, `categories` ⊆
  `lattice.categories`) et, optionnellement, une frontière (`boundary`).
- Un flux du consommateur `c` vers le consommé `s` est permis ssi
  `étiquette(zone(s)) ≤ étiquette(zone(c))` (§5.4).

**Composition.** Quand une stack utilise plusieurs patrons, leurs treillis
DOIVENT être identiques ou l'un DOIT étendre l'autre (mêmes niveaux dans le
même ordre ; catégories en sur-ensemble), sinon **E050**. Une zone de même
nom définie deux fois avec des étiquettes différentes : **E051**.

**Sans patron**, une stack utilise le patron intégré `hamac-default` : niveaux
et zones `public` < `default` < `internal` < `secure`, sans catégorie, sans
contrainte. C'est exactement la sémantique de la version 1.0.

### 6.3 Frontières de zone : `boundary`

| Valeur | Sens |
|---|---|
| `firewall` (défaut) | filtrage avec état ; les flux déclarés ouvrent des connexions |
| `diode` | passerelle **unidirectionnelle** du bas vers le haut : rien ne sort de la zone vers une zone moins sensible |

À travers une `diode`, aucune requête ne peut recevoir de réponse. Un
`consumes` d'un service de la zone haute vers un service de la zone basse
DOIT donc être un **flux poussé** : il déclare `mode: push`, et le service
consommé émet ce que le consommateur reçoit (réplication, flux d'événements,
fichiers). Un `consumes` sans `mode: push` qui traverse une diode est refusé
(**E041**). *Le champ `consumes[].mode` (`request` par défaut, `push`) est
expérimental.*

Une zone derrière une diode a son propre plan de contrôle : un contrôleur
extérieur ne pourrait pas en recevoir les rapports. Hamac produit une
infrastructure par enclave ; les manifestes signés montent par la diode.

### 6.4 Axes d'assurance — *expérimental*

Trois axes, à valeurs ordonnées, fixés par le format en 1.1 :

| Axe | Valeurs, de la plus faible à la plus forte |
|---|---|
| `boot` | `none` < `provider-vtpm` < `confidential-vm` < `measured-tpm2` |
| `operator` | `any` < `eu` < `secnumcloud` < `self` |
| `physical` | `third-party` < `dedicated-rack` < `site` |

Un nœud **offre** une valeur par axe (inventaire, constatée par
`hamac verify`) ; une zone ou un service **exige** un minimum. Un placement
est admissible ssi l'offre ≥ l'exigence sur chaque axe. `assurance` d'un
patron associe à un nom de zone l'exigence de cette zone ; un axe absent
n'impose rien.

### 6.5 Contraintes — *expérimental*

Une contrainte a un `id` unique dans le patron, une `description`, une
`severity` (`hard`, défaut, ou `soft`), un `weight` pour les `soft`, et une
expression `expr` dans le langage ci-dessous.

**Modèle.** Une expression porte sur une **topologie candidate** : ensembles
finis `services`, `zones`, `hosts`, `flows`, `volumes`, `replicas`, et les
fonctions qui les relient. Hamac instancie les quantificateurs sur le parc
et la stack réels, puis confie le problème à un solveur. Toute solution est
revérifiée par un vérificateur indépendant avant d'être acceptée.

**Grammaire (EBNF).**

```
expr     ::= quant | impl
quant    ::= ("forall" | "exists") IDENT "in" set ["where" expr] ":" expr
impl     ::= disj ["=>" impl]
disj     ::= conj { "or" conj }
conj     ::= neg { "and" neg }
neg      ::= "not" neg | cmp
cmp      ::= term [ relop term ]
relop    ::= "=" | "!=" | "<" | "<=" | ">" | ">=" | "in" | "subset"
term     ::= sum
sum      ::= prod { ("+" | "-") prod }
prod     ::= atom { "*" INT }
atom     ::= INT | QUANTITY | STRING | IDENT
           | IDENT "(" [ term { "," term } ] ")"
           | IDENT "." IDENT
           | "(" expr ")"
set      ::= DOMAIN | IDENT "(" term ")"
DOMAIN   ::= "services" | "zones" | "hosts" | "flows" | "volumes"
QUANTITY ::= INT ("Ki"|"Mi"|"Gi"|"Ti"|"m")
```

L'arithmétique est **linéaire** : un produit a toujours un facteur
constant. Il n'y a ni récursion ni quantification sur des ensembles
d'ensembles. Le langage reste donc **décidable** sur domaine fini, et une
contradiction s'explique par un ensemble minimal de contraintes en conflit.

**Fonctions de base.**

| Fonction | Type | Sens |
|---|---|---|
| `zone(s)` | service → zone | zone du service |
| `level(z)` | zone → niveau | niveau de la zone ; comparable par `<`, `<=` |
| `categories(z)` | zone → ensemble | |
| `hosts_of(s)` | service → ensemble d'hôtes | hôtes portant une réplique |
| `levels_on(h)` | hôte → ensemble de niveaux | niveaux des zones placées sur l'hôte |
| `failure_domains(H)` | ensemble d'hôtes → ensemble | domaines de panne couverts |
| `count(E)` | ensemble → entier | cardinal |
| `sum(E, f)` | ensemble, fonction → entier | somme |
| `stateful(s)` | service → booléen | possède un volume `local` ou `replicated` |
| `src(f)`, `dst(f)` | flux → service | |
| `h.boot`, `h.operator`, `h.physical` | hôte → valeur d'axe | assurance offerte |
| `h.memory`, `h.cpu` | hôte → quantité | capacité |
| `has(h, c)` | hôte, capacité → booléen | capacité offerte |
| `moves` | entier | nombre de répliques déplacées par rapport à la topologie courante |

Une expression mal typée, une fonction inconnue, ou un identifiant non lié :
**E052**, avec la position dans l'expression.

### 6.6 Objectifs — *expérimental*

`objectives` est une liste ordonnée de `minimize: <terme>` ou
`maximize: <terme>`, avec `priority` (1 = plus important). L'optimisation
est **lexicographique** par priorité ; à priorité égale, les termes sont
sommés avec leurs `weight`. Les contraintes `soft` entrent dans l'objectif
comme des pénalités pondérées.

### 6.7 Résultat de la résolution

- **Satisfiable** : la topologie retenue est écrite dans un
  `kind: infrastructure` (§8), accompagnée d'un **certificat** (patrons, parc,
  solution, verdict du vérificateur).
- **Insatisfiable** : Hamac rapporte un ensemble minimal de contraintes en
  conflit, chacune avec son patron, son `id` et les chemins YAML des
  déclarations qui l'activent. Il produit aussi la **liste de courses** :
  ce qu'il faudrait ajouter au parc pour lever le conflit, quand c'est
  calculable (**E060**).

---

## 7. `kind: stack` — *stable*

```yaml
manifest_version: "1.1"
kind: stack
name: si-ocamlpro
patterns: [anssi-renforce, si-ocamlpro-local]
accept_experimental: true
services:
  - ref: services/hr-api.sieste.yml
    replicas: 3
    consumes:
      - name: db
        provider: postgresql-ha
infrastructure: infra/si-ocamlpro.infra.yml
```

| Champ | Règle |
|---|---|
| `patterns` | noms de patrons appliqués (§6). Absent : `hamac-default` |
| `accept_experimental` | `true` supprime **W001** pour toute la stack |
| `services[].ref` | chemin d'un manifeste `service`, relatif à la stack (**E021** s'il est introuvable) |
| `services[].replicas` | surcharge de `replicas` |
| `services[].consumes[]` | force le provider (`provider`, nom d'un service-provider) d'un `consumes` nommé (**E022** si le nom n'existe pas dans le service) |
| `infrastructure` | chemin d'une infrastructure imposée ; absent = calculée |

---

## 8. `kind: infrastructure` — *stable, produit par Hamac*

Un manifeste d'infrastructure est **la sortie** du planner, éventuellement
relue et figée par un opérateur. Il reste lisible et modifiable à la main ;
une infrastructure modifiée est revérifiée contre les patrons de la stack
avant tout déploiement.

| Champ | Règle |
|---|---|
| `backend` | `physical` \| `incus` \| `qemu` \| `kubernetes` \| `docker-compose` |
| `minimum_requirements` | `min_nodes`, `total_ram`, `total_cpu` |
| `proposed_topology.nodes[]` | `role`, `count`, `ram`, `cpu`, `boot`, `os_image`, `os_sha256`, `isolated`, `provisioning_profile` |
| `proposed_topology.segments[]` | `name`, `cidr`, `vlan` |
| `proposed_topology.firewall[]` | règles textuelles `ALLOW\|DENY <zone> -> <zone> [(détail)]`, où un détail `a -> b` désigne le flux déclaré qui justifie la règle |
| `warnings` | liste de chaînes |
| `certificate` | *expérimental* : référence au certificat de résolution (§6.7) |

Chaque règle `ALLOW` DOIT porter le flux qui la justifie (**E045**). Une
règle sans justification n'est pas une erreur de syntaxe mais un défaut de
traçabilité, que le validateur refuse.

---

## 9. `kind: provisioning_profile` et `kind: bundle`

Format défini par [`PROVISIONING_SPEC.md`](PROVISIONING_SPEC.md). Ajouts
1.1 :

- **Cycle de vie d'un bundle** — *expérimental* : `lifecycle: install`
  (défaut ; appliqué une fois, au premier démarrage) ou `lifecycle:
  converge` (appliqué à l'installation **et** en cours de vie par l'agent).
  Un bundle `converge` DOIT décrire un état, pas une séquence : il est
  appliqué de façon idempotente, et un écart constaté est une **dérive**.
  C'est ce qui permet d'adopter une machine qui n'a pas été installée par
  Hamac.
- **Assurance offerte** — *expérimental* : un profil PEUT déclarer
  `assurance:` (§6.4), ce que garantit une machine installée par lui. Une
  machine adoptée la constate par `hamac verify`.

---

## 10. Validation : règles et catalogue des erreurs

### 10.1 Trois étages

1. **Syntaxe et types** (manifeste seul) : YAML valide, champs connus, types,
   formats. Commande : `hamac validate <fichiers…>`.
2. **Références** (ensemble de manifestes) : `ref` résolus, providers
   trouvés, gabarits liés, zones définies. Commande : `hamac validate` sur une
   stack.
3. **Sémantique** (stack + patrons, puis parc) : treillis, cohérence des
   étiquettes, contraintes des patrons. Commande : `hamac plan`.

Chaque diagnostic donne : un identifiant, le fichier, le **chemin YAML**
(`security.route_labels.1.classification`), un message. Une **erreur**
(`E…`) fait échouer la commande ; un **avertissement** (`W…`) non, sauf avec
`--strict`.

### 10.2 Catalogue

Chaque code est couvert par au moins un manifeste d'erreur dans
`tests/manifests/invalid/` ; le validateur DOIT les refuser tous, et DOIT
accepter tous ceux de `examples/`.

| Code | Étage | Condition |
|---|---|---|
| E001 | 1 | YAML invalide, ou racine qui n'est pas un objet |
| E002 | 1 | `manifest_version` absent, mal formé, ou non supporté (§2.1) |
| E003 | 1 | champ inconnu, ou réservé (§2.3, §3) |
| E004 | 1 | `name` qui n'est pas un nom DNS |
| E005 | 1 | `kind` inconnu |
| E006 | 1 | champ obligatoire absent |
| E007 | 1 | type incorrect |
| E010 | 2 | deux manifestes de même `kind` et même `name` dans une stack |
| E011 | 1 | `sha256` qui n'est pas 64 caractères hexadécimaux |
| E012 | 1 | nom dupliqué dans une liste (`consumes`, `storage`, `secrets`) |
| E013 | 1 | `consumes` sans, ou avec à la fois, `capability` et `service` |
| E014 | 1 | requête de ressource supérieure à sa limite |
| E015 | 1 | quantité ou unité invalide |
| E016 | 1 | `autoscaling` incohérent, ou `replicas < 1` |
| E020 | 2 | gabarit invalide, ou référence non liée (`{secret.x}`, clé absente des `provides`) |
| E021 | 2 | `ref` de stack introuvable |
| E022 | 2 | surcharge de `consumes` qui ne correspond à aucune entrée du service |
| E023 | 2 | aucun provider pour une `capability`, ou plusieurs sans surcharge |
| E030 | 1 | `volumes` et `storage` dans le même service |
| E031 | 1 | `mount` non absolu |
| E032 | 1 | `size` absent pour un volume persistant |
| E033 | 1 | volume `local` sans `backup` ni `rebuild` |
| E034 | 1 | secret sans, ou avec à la fois, `ref` et `generate` |
| E035 | 1 | `exposure.port` absent de `ports` |
| E040 | 3 | flux qui lit vers le haut |
| E041 | 3 | flux de type requête à travers une diode |
| E042 | 2 | zone inconnue des patrons de la stack |
| E043 | 1 | étiquette de route `public` combinée à une exigence |
| E044 | 3 | étiquette de route au-dessus de la zone du service |
| E045 | 3 | règle `ALLOW` sans flux justificatif |
| E050 | 2 | treillis de patrons incompatibles |
| E051 | 2 | zone définie deux fois avec des étiquettes différentes |
| E052 | 1 | expression de contrainte mal formée ou mal typée |
| E060 | 3 | contraintes insatisfiables (avec explication) |
| W001 | 1 | champ expérimental utilisé sans `accept_experimental` |
| W002 | 1 | forme dépréciée (avec son remplaçant) |
| W010 | 1 | image OCI non épinglée par digest |
| W011 | 1 | `health_check.timeout ≥ interval` |
| W012 | 1 | valeur d'environnement qui ressemble à un secret littéral |

---

## 11. Schéma JSON

Un schéma JSON (draft 2020-12) est publié pour chaque version du format :
`doc/schema/hamac-manifest-1.1.schema.json`. Il couvre l'étage 1, ce qui
suffit aux éditeurs et aux générateurs tiers pour valider et compléter un
manifeste. Les étages 2 et 3 restent du ressort de `hamac validate` et
`hamac plan`. En cas de divergence, ce document fait foi.

---

## 12. Historique

| Version | Date | Changements |
|---|---|---|
| 1.0 | 2025 | `service`, `stack`, `infrastructure` ; `provisioning_profile` et `bundle` (PROVISIONING_SPEC v0.1). Spécification implicite (code et exemples) |
| 1.1 | 2026-10 | première spécification écrite ; versionnement et stabilité ; refus des champs inconnus ; noms DNS ; `security` étendu (niveaux, catégories, rôles, routes publiques) ; `kind: pattern` (treillis, zones, diodes, assurance, contraintes, objectifs) ; `storage`, `backup`, `secrets`, `placement`, `exposure` (expérimentaux) ; `volumes` et `ports[].host` dépréciés ; catalogue des erreurs |

---

## Financement

> « Ce projet a été financé par le Gouvernement dans le cadre du plan France 2030
> opéré par Cap Digital et financé par l'Union européenne – NextGeneration EU »
>
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
  &nbsp;&nbsp;
  <img src="assets/cap-digital.png" alt="Cap Digital" height="48">
</p>

Provenance et règles d'usage des logos : [`assets/SOURCES.md`](assets/SOURCES.md).
