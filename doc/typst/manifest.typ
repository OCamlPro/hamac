// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com>

#import "theme.typ": *

#show: document-officiel.with(
  titre: "Spécification des manifestes",
  sous-titre: [Le vocabulaire LOAF de Hamac (module `hamac` 0.2.0) et les
    vérifications effectuées au chargement des manifestes.],
  nature: "Spécification",
  version: "0.2",
  date: "2026-10-30",
  statut: "brouillon",
  reference: [Hyper Open X — jalon J2],
)

= Objet et principes

Ce document définit les manifestes de Hamac : ce qu'ils décrivent, les
champs de chaque sorte de manifeste, les valeurs par défaut que Hamac
applique et les diagnostics qu'il émet. Un manifeste conforme peut être écrit
à la main ou produit par un script, un langage de plus haut niveau ou tout
autre générateur.

Les manifestes sont écrits en *LOAF*, un langage de manifestes défini par sa
propre spécification (document « LOAF », `spec/loaf.typ` du dépôt `loaf`) :
syntaxe, blocs, champs et marques de cardinalité, tables et listes, gabarits
`fmt`, modules et versions, codes de refus `L001` à `L014`. Le présent
document ne reprend pas cette définition. Il décrit le *vocabulaire* de
Hamac, c'est-à-dire les blocs, les champs et les règles que Hamac fournit au
langage, puis les contrôles que Hamac ajoute.

L'implémentation de référence est la bibliothèque `hamac-manifest`
(`pkgs/hamac-manifest/`), qui lit et valide des manifestes sans dépendre du
reste de Hamac. Le vocabulaire est le fichier
`pkgs/hamac-manifest/vocabulary/hamac.loaf` (module `hamac`, version 0.2.0) ;
pour la forme d'un champ, ce fichier fait foi.

== Sortes de manifestes <sortes>

Hamac connaît six sortes de manifestes. Chacune est un bloc du vocabulaire, et
chacune a son auteur :

#tableau((auto, 1fr, 1.4fr),
  [Bloc], [Auteur], [Contenu],
  [`service`], [l'équipe de développement], [une unité déployable, ses
    ressources, ses dépendances et sa sensibilité (@service) ; un service qui
    fournit une capacité générique (base de données, cache) à d'autres
    services est un #terme[provider] (@capacites)],
  [`pattern`], [la personne responsable de la sécurité], [un treillis de
    sensibilité, des zones, des exigences d'assurance et des contraintes sur
    la topologie (@pattern)],
  [`stack`], [l'équipe d'exploitation], [les services à déployer ensemble et
    les choix qui les concernent (@stack)],
  [`infrastructure`], [le planner de Hamac, relu par l'exploitation], [une
    topologie : nœuds, segments réseau, filtrage (@infrastructure)],
  [`provisioning_profile`], [l'administration du parc], [le système installé
    sur une machine (@profil)],
  [`bundle`], [l'administration du parc], [une brique réutilisable d'un
    profil (@bundle)],
)

== Principes

+ *Infrastructure inférée.* Un service déclare ses besoins : ressources,
  dépendances, sensibilité, stockage. Hamac calcule une topologie qui les
  satisfait. Un manifeste de service ne nomme aucune machine.
+ *Secrets par référence.* Aucun champ ne contient de secret en clair : un
  secret est une référence vers un coffre, ou une valeur que Hamac engendre.
+ *Validation stricte.* Un champ inconnu, une référence à un manifeste absent
  ou un flux contraire au treillis entraînent le refus des manifestes. Chaque
  diagnostic donne un code et l'emplacement de l'instruction fautive
  (@validation).
+ *Vocabulaire versionné.* Le vocabulaire est un module LOAF ; sa version
  suit les règles de compatibilité du langage (@stabilite).

Les mots #doit, #doit-pas, #devrait et #peut ont le sens des RFC 2119 et 8174.

= Exemple <exemple>

L'exemple décrit une petite application de ressources humaines : un portail
public, une API qui expose les données du personnel en s'appuyant sur une
base PostgreSQL, et un traitement qui consolide la paie à partir de l'API.
Il tient en quatre parties : le patron de l'organisation, le provider de base
de données, les services et la stack qui les réunit. Les fichiers complets
sont dans `examples/hr-stack/` et `providers/` ; les extraits omettent les
lignes `loaf 0.1.` et `use hamac 0.2.` qui ouvrent chaque fichier.

== Le patron de l'organisation

```loaf
module exemple_rh 1.0.0.

pattern exemple_rh {
  % Les niveaux de sensibilité, du moins au plus sensible.
  levels [public, internal, confidential].
  % Les catégories de besoin d'en connaître.
  category rh; finance.
  % Les rôles que l'organisation attribue à ses utilisateurs.
  role rh; comptable; admin.

  % Les zones : chacune porte un niveau et des catégories.
  zone public { level public. }
  zone internal { level internal. }
  zone rh {
    level confidential.
    category rh; finance.
  }

  % Les machines de la zone rh ont un démarrage mesuré par TPM et sont
  % sur le site de l'organisation.
  assurance rh, boot, measured_tpm2.
  assurance rh, physical, site.
}
```

Le patron est écrit par la personne responsable de la sécurité. Il fixe le
vocabulaire de sensibilité que les services emploient : trois niveaux
ordonnés, deux catégories, trois rôles, et trois zones. Une zone est un
ensemble de machines et de services qui partagent une même étiquette : la
zone `rh` accueille des données confidentielles des catégories `rh` et
`finance`. Le patron est un module : la stack le charge par
`use exemple_rh 1.0.` Le fichier complet ajoute des contraintes sur la
topologie (@contraintes).

== Le provider de base de données

```loaf
service postgresql {
  runtime http.
  capability database.            % il fournit une base de données
  input user, gen(alpha, 12).      % engendré pour chaque consommateur
  input password, gen(alnum, 32).
  input dbname, cat(consumer(name), "_db").
  environment "POSTGRES_USER", input(user).
  environment "POSTGRES_PASSWORD", input(password).
  environment "POSTGRES_DB", input(dbname).
  port 5432 { protocol tcp. }
}

% Ce que le provider offre à ses consommateurs : le contrat database.
database postgresql {
  host instance(name).
  port 5432.
  user input(user).
  password input(password).
  dbname input(dbname).
}
```

Un provider est un service comme un autre, qui déclare une capacité
(`database`). Hamac en crée une instance par service qui le consomme : chaque
consommateur reçoit sa propre base et ses propres identifiants, tirés au
hasard au déploiement. Le bloc `database postgresql` remplit le contrat de
la capacité : les attributs que tout provider de base de données offre à ses
consommateurs (@contrats).

== Les services

```loaf
service hr_api {
  runtime http.
  replicas 2.                      % deux instances
  zone rh.                         % il traite des données de la zone rh
  spread failure_domain.           % sur deux domaines de panne distincts

  % Une base de données, sans nommer le provider : Hamac le choisit, et
  % remplit le gabarit avec les attributs de son contrat.
  consumes db {
    capability database.
    inject "DATABASE_URL",
           fmt("postgresql://{~.database.user}:{~.database.password}@{~.database.host}:{~.database.port}/{~.database.dbname}").
  }

  route "/health" { public. }
  route "/employees/salaries" {
    classification confidential.
    category rh; finance.
    required_clearance comptable; admin.
  }

  port 8080 {}
}

service payroll_report {
  runtime batch.
  zone rh.

  % L'API RH, nommée : un flux réseau de payroll_report vers hr_api.
  consumes api {
    service hr_api.
    inject "HR_API_URL", fmt("http://{~.host}:{~.port}").
  }

  % Un cache sur le disque du nœud, qu'il suffit de recalculer.
  storage cache {
    mount "/var/cache/report".
    class local.
    size 5, gi.
    rebuild none.
  }
}

service portal {
  runtime http.
  replicas 2.
  zone public.
  port 8080 {}
}
```

Le bloc `service hr_api` décrit le service sans répéter son nom : chaque
instruction s'applique à `hr_api`. Le bloc `consumes db` déclare un besoin,
une base de données ; dans ce bloc, `~` désigne la consommation, et
`~.database.user` l'attribut `user` du contrat du provider que Hamac lui
associera. Une route fixe les conditions d'accès à un chemin HTTP : seul un
utilisateur habilité au niveau `confidential`, détenteur des catégories `rh`
et `finance` et du rôle `comptable` ou `admin`, lit les salaires.

== La stack

```loaf
use exemple_rh 1.0.

stack hr {
  description "Application RH : portail public, API RH, consolidation".
  accept_experimental.

  service portal {}
  service hr_api {}
  service payroll_report {}
}
```

La stack est écrite par l'équipe d'exploitation. Elle nomme les services à
déployer et charge le patron. Un service de l'ensemble qu'elle ne nomme pas,
ici `postgresql`, est un provider : il n'est déployé que pour les services qui
le consomment.

== Ce que Hamac en déduit

Les commandes `hamac validate`, `hamac resolve` et `hamac plan`, appliquées
aux dossiers `examples/hr-stack` et `providers`, établissent :

- La consommation `db` de `hr_api` est résolue vers `postgresql`, seul
  provider de `database` de l'ensemble. Hamac crée l'instance
  `postgresql-hr-api-db` ; au déploiement, `DATABASE_URL` vaut
  `postgresql://<12 lettres>:<32 caractères>@postgresql-hr-api-db:5432/hr_api_db`.
- `payroll_report` reçoit `HR_API_URL=http://hr-api:8080` : le nom d'hôte de
  `hr_api` et son premier port. Hamac le calcule ; les manifestes ne
  l'écrivent jamais.
- `payroll_report` et `hr_api` sont dans la même zone : le flux entre eux ne
  demande aucune règle de filtrage. Entre les zones `public` et `rh`, tout est
  refusé : aucun flux n'est déclaré, et `public` ne peut de toute façon pas
  lire `rh`.
- Le planificateur propose trois nœuds : un pour `public`, deux pour `rh`,
  car les deux répliques de `hr_api` doivent être sur des domaines de panne
  distincts.
- Si `portal` déclarait `consumes api { service hr_api. }`, l'ensemble serait
  refusé (#code("E040")) : `portal` (zone `public`) ouvrirait une connexion
  vers une zone plus sensible, ce qui revient à la lire.
- Une route qui exigerait le rôle `admn`, mal orthographié, serait refusée
  (#code("E045")) : aucun patron ne déclare ce rôle.
- `zone dmz.` dans un service serait refusée (#code("E042")) : le patron ne
  définit pas cette zone.

= Manifestes LOAF <loaf>

== Fichier et vocabulaire

Un fichier de manifestes commence par la version du langage qu'il suit, puis
charge le vocabulaire de Hamac par `use` :

```loaf
loaf 0.1.
use hamac 0.2.

service portal {
  runtime http.
  replicas 2.
  port 8080 {}
}
```

Un manifeste est un bloc du vocabulaire. Le sujet du bloc est le nom du
manifeste : ici, le service `portal`. Un fichier #peut contenir plusieurs
manifestes, de sortes différentes ou non. Un bloc ou un champ que le
vocabulaire ne déclare pas est refusé par le langage (#code("L001")) ; une
faute de frappe (`replica 3.`) est donc détectée.

== Ensemble de fichiers <ensemble>

Hamac charge toujours des manifestes ensemble : les fichiers donnés à une
commande forment un *ensemble*, dont le modèle est calculé en une fois. Un
répertoire donné en argument vaut les fichiers `.loaf` qu'il contient, à toute
profondeur :

```sh
hamac validate examples/hr-stack providers
```

- Une référence d'un manifeste à un autre (une stack à ses services, un
  profil à ses bundles, une consommation au service qu'elle nomme) est
  vérifiée par le langage : le manifeste nommé #doit faire partie de
  l'ensemble (#code("L002") sinon).
- Un même bloc ouvert dans plusieurs fichiers réunit leurs contenus. Un
  fichier peut ainsi compléter un manifeste d'un autre fichier ; comme deux
  définitions indépendantes d'un même nom se réunissent de la même façon,
  Hamac le signale par l'avertissement #code("W003"). Deux valeurs pour un
  champ qui n'en admet qu'une sont refusées (#code("L006")).

```loaf
% web.loaf
loaf 0.1.
use hamac 0.2.

service web {
  runtime http.
  artifact "./bin/web" {
    sha256 "0000000000000000000000000000000000000000000000000000000000000000".
    format native.
    arch amd64.
  }
}
```

```loaf
% web-prod.loaf : W003 « service web is defined in web-prod.loaf and web.loaf »
loaf 0.1.
use hamac 0.2.

service web { replicas 3. }
```

== Modules et bibliothèques <modules>

Le vocabulaire et les patrons (@pattern) sont des modules LOAF : des fichiers
qui déclarent leur nom et leur version (`module exemple_rh 1.0.0.`), chargés
par `use exemple_rh 1.0.` depuis l'ensemble ou depuis un répertoire de
bibliothèque. Hamac cherche les modules, dans cet ordre :

+ dans le répertoire du vocabulaire : celui qu'installe le paquet
  `hamac-manifest`, ou celui que nomme la variable `HAMAC_VOCABULARY` ;
+ dans les répertoires donnés par l'option `-L DIR` (répétable) ;
+ dans `./patterns`, puis dans `~/.hamac/patterns`, s'ils existent.

La sélection des versions, la compatibilité entre une contrainte et une
version et le fichier d'empreintes `loaf.sum` suivent la spécification de
LOAF ; un module introuvable ou des contraintes incompatibles sont refusés
(#code("L009")).

== Outils

L'outil `loaf`, qui accompagne la spécification de LOAF, s'applique aux
manifestes de Hamac, le répertoire du vocabulaire étant donné comme
bibliothèque (`-L`) :

- `loaf fmt` réécrit des fichiers dans la forme canonique du langage ;
- `loaf export` écrit le modèle d'un ensemble dans le format d'échange de
  LOAF, une ligne JSON par fait, avec l'emplacement des instructions qui le
  dénotent :

```
{"args":["hr_api","rh"],"at":[{"column":3,"file":"hr-api.loaf","line":13}],"pred":"service.zone"}
```

== Stabilité <stabilite>

La version du module `hamac` suit les règles de compatibilité de LOAF : un
ajout de champ optionnel ou de valeur d'énumération est une version mineure,
un retrait ou un changement de forme une version majeure. Un manifeste qui
charge `use hamac 0.2.` reste valide avec toute version 0.2.x du
vocabulaire.

Certains champs sont #experimental : leur sens peut encore changer dans une
version mineure. Leur usage produit l'avertissement #code("W001"), une fois par
manifeste et par groupe de champs, sauf si l'ensemble contient une stack qui
écrit `accept_experimental` (@stack). Les autres champs sont #stable.

#tableau((auto, 1fr),
  [Bloc], [Champs expérimentaux],
  [`service`], [`storage`, `backup`, `secret`, le placement (`need`,
    `assurance`, `spread`, `affinity`, `anti_affinity`), `exposure`, et le
    champ `mode` d'une consommation],
  [`pattern`], [`assurance`, `constraint`, `minimize`, `maximize`],
  [`infrastructure`], [`certificate`],
  [`provisioning_profile`], [`assurance`],
  [`bundle`], [`lifecycle`],
)

= Conventions du vocabulaire <conventions>

== Lecture des tableaux de champs

Chaque section décrit un bloc par un tableau dont la première colonne reprend
la déclaration du champ dans le vocabulaire : son nom, sa marque de
cardinalité, la sorte de ses valeurs. Les marques ont le sens que leur donne
LOAF :

#tableau((auto, 1fr),
  [Marque], [Nombre de valeurs par bloc],
  [aucune], [exactement une : le champ est obligatoire (#code("L007") s'il
    manque, #code("L006") s'il en a deux)],
  [`?`], [au plus une],
  [`*`], [un nombre quelconque],
)

Un champ sans sorte (`public.`, `required.`) est un drapeau, présent ou
absent. `f* k => v` déclare une table, qui associe une valeur à chaque clé ;
`f* [s]` déclare une liste, écrite entre crochets. Les sortes `string`,
`int`, `name` et `text` sont celles de LOAF ; une sorte qui porte le nom d'un
bloc (`service`, `bundle`) désigne les manifestes de ce bloc présents dans
l'ensemble ; une sorte qui porte le nom d'une énumération en désigne les
valeurs. Un sous-bloc (`port* int { … }`) a pour sujet une valeur de la sorte
indiquée.

Hamac applique la valeur indiquée comme « défaut » quand un champ optionnel
est absent.

== Noms

- Le nom d'un manifeste est une constante LOAF (`hr_api`). Hamac l'emploie
  tel quel partout : dans les références entre manifestes, ses diagnostics,
  ses sorties et les valeurs qu'il engendre (la base attribuée à `hr_api`
  s'appelle `hr_api_db`).
- Seul un *nom d'hôte* change de forme, parce qu'il n'admet pas `_` : celui
  d'un service, d'une instance de provider ou d'un nœud remplace `_` par
  `-` (`hr-api`, `postgresql-hr-api-db`). Aucun manifeste n'a à l'écrire : un
  consommateur reçoit le nom d'hôte du service qu'il consomme par son
  gabarit (`{~.host}`, @consumes). Le nom d'un service #doit donc ne
  contenir que des minuscules, des chiffres et `_`, ni commencer ni finir
  par `_`, et ne pas dépasser 63 caractères (#code("E004")).
- Les valeurs des énumérations s'écrivent avec `_` là où le nom usuel porte
  `-` : `oci_image`, `measured_tpm2`, `docker_compose`.
- Un champ à plusieurs valeurs porte un nom au singulier ; chaque instruction
  en donne une : `port 8080 { … }`, `secret session_key { … }`,
  `category rh; finance.`
- Un objet unique est un sous-bloc quand il a un identifiant naturel, qui en
  est le sujet : `artifact`, `health_check`, `metrics`, `backup`, `os`. Sinon
  ses champs sont ceux du bloc qui le contient (ressources, placement, mise à
  l'échelle), préfixés quand leur nom serait ambigu (`memory_limit`,
  `readiness_timeout`).

== Quantités et durées <quantites>

Une quantité s'écrit comme un couple (entier, unité) : `memory_limit 512, mi.`
pour 512 Mio. Les unités sont des énumérations :

#tableau((auto, auto, 1fr),
  [Sorte], [Valeurs], [Sens],
  [`size_unit`], [`ki` · `mi` · `gi` · `ti`], [Kio, Mio, Gio, Tio : unités
    binaires (ci-dessous)],
  [`cpu_unit`], [`core` · `m`], [cœurs ; millicœurs, un cœur valant 1000 m
    (`500, m` : un demi-cœur)],
  [`time_unit`], [`s` · `min` · `h` · `d`], [secondes, minutes, heures,
    jours],
)

*Unités binaires.* Les tailles s'expriment en multiples de 1024, selon les
préfixes binaires de la norme CEI 60027-2 :

#tableau((auto, auto, 1fr),
  [Unité], [Nom], [Octets],
  [`ki`], [kibioctet (Kio)], [1024],
  [`mi`], [mébioctet (Mio)], [1024 × 1024 = 1 048 576],
  [`gi`], [gibioctet (Gio)], [1024#super[3] = 1 073 741 824],
  [`ti`], [tébioctet (Tio)], [1024#super[4] = 1 099 511 627 776],
)

Ces unités ne sont pas le kilooctet, le mégaoctet ou le gigaoctet du système
international (ko, Mo, Go), qui valent 1000, 1000#super[2] et
1000#super[3] octets : 1 Gio vaut environ 1,074 Go, et l'écart croît avec
l'unité. Ce sont celles de la mémoire et des outils vers lesquels Hamac
traduit les manifestes (Kubernetes, groupes de contrôle Linux, volumes des
clouds). Une taille connue en unités décimales se convertit en arrondissant
au-dessus : un volume de 500 Go (500 × 1000#super[3] octets, soit environ
465,7 Gio) s'écrit `size 466, gi.`
Les délais des sondes (`health_check`, `readiness_interval`,
`readiness_timeout`) sont des entiers, en secondes.

== Métadonnées

Tous les blocs de manifeste acceptent les mêmes métadonnées :

#tableau((auto, 1fr),
  [Déclaration], [Sens],
  [`description? string`], [texte libre],
  [`label* string => string`], [clés et valeurs courtes, pour les sélecteurs :
    `label "team", "rh".`],
  [`annotation* string => string`], [données libres, que Hamac ignore ; un
    générateur tiers peut y placer les siennes],
)

== Termes rendus par Hamac <rendus>

Certaines valeurs ne sont connues qu'au déploiement : un mot de passe tiré au
hasard, le nom d'une instance, la valeur d'un secret. Le vocabulaire les
déclare comme des termes que Hamac rend (déclarations `render` de LOAF). Ils
restent opaques pour les règles du langage, et peuvent paraître partout où un
champ attend une valeur de sorte `text`, seuls ou dans un gabarit `fmt`.

Hamac crée une *instance* d'un provider pour chaque consommation qui le
retient : chaque consommateur reçoit sa propre base, ses propres
identifiants. Les
termes suivants désignent des valeurs de cette instance.

#tableau((auto, 1fr, 1fr),
  [Terme], [Valeur rendue], [Usage],
  [`gen(alnum, 32)`, `gen(alpha, 12)`], [32 caractères alphanumériques,
    12 lettres minuscules, tirés au hasard], [entrées d'un provider],
  [`input(user)`], [la valeur de l'entrée `user` de l'instance], [champs d'un
    provider],
  [`consumer(name)`], [le nom du service consommateur], [entrées d'un
    provider],
  [`instance(name)`], [le nom de l'instance, qui est aussi son nom d'hôte],
    [champs d'un provider],
  [`host(t)`], [le nom d'hôte du service `t`], [injection d'une
    consommation de `t`, contrat de la capacité de `t`],
  [`secret(x)`], [la valeur du secret `x` déclaré par le service],
    [variables d'environnement et injections],
)

- Le tirage aléatoire utilise le générateur cryptographique du système ;
  l'option `--seed` des commandes qui résolvent les manifestes le rend
  reproductible, pour les tests seulement.
- `host(t)` employé ailleurs que dans une consommation de `t` ou que dans le
  contrat de la capacité de `t`, et `instance(x)` pour un autre attribut que
  `name`, n'ont pas de valeur : #code("E020").
- La valeur d'un `secret(x)` n'est écrite dans aucun fichier produit par
  Hamac : l'agent l'injecte au démarrage du service.

= Service <service>

#stable

Un service est une unité déployable : un artefact, son exécution, ses
ressources. Cette section décrit les champs d'exécution ; les sections
suivantes décrivent les dépendances (@capacites), les données (@donnees) et la
sécurité (@securite).

== Exécution

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`runtime runtime`], [nature de la charge : `http` · `cli` · `batch` ·
    `eventloop` · `custom`. `http` active les sondes HTTP et l'exposition],
  [`artifact? string { … }`], [ce qui s'exécute ; le sujet est un chemin, une
    URL ou une référence d'image OCI (ci-dessous)],
  [`replicas? int`], [nombre d'instances ; défaut 1, au moins 1
    (#code("E016"))],
  [`port* int { protocol? port_protocol. }`], [port écouté par le service ;
    protocole `tcp` (défaut) ou `udp`],
  [`environment* string => text`], [variables d'environnement ; une valeur
    peut être un terme rendu ou un gabarit (@rendus)],
)

Le sous-bloc `artifact` porte :

#tableau((auto, 1fr),
  [Déclaration], [Sens et contrôles],
  [`sha256 string`], [empreinte de l'artefact : 64 caractères hexadécimaux
    (#code("E011"))],
  [`format artifact_format`], [`oci_image` · `native` · `incus_vm_image` ·
    `incus_system_image`],
  [`arch* arch`], [architectures du processeur où l'artefact s'exécute :
    `amd64` · `arm64` ; défaut `amd64`. Seule une image OCI en a plusieurs
    (image multi-architecture) ; un autre format en a une seule
    (#code("E008"))],
)

Le format détermine l'exécutant : un `oci_image` s'exécute dans un conteneur,
un binaire `native` (Linux) directement, un `incus_vm_image` dans une
machine virtuelle, un `incus_system_image` dans un conteneur système. Aucun
autre champ ne le précise.

*Architecture.* Une réplique ne s'exécute que sur un nœud d'une des
architectures de son artefact. Les répliques d'un service ont toutes la
même architecture ; pour une image multi-architecture, le planificateur la
choisit. Il propose des nœuds de chaque architecture nécessaire, et une
infrastructure imposée par la stack #doit en offrir à chaque service dans sa
zone (@infrastructure). Une image OCI #devrait être épinglée par son empreinte, écrite dans
le sujet (`registry.example.org/rh/portal@sha256:…`), sinon #code("W010").

== Ressources et mise à l'échelle

#tableau((auto, 1fr),
  [Déclaration], [Sens et contrôles],
  [`memory_request? int, size_unit`], [mémoire réservée],
  [`memory_limit? int, size_unit`], [mémoire maximale],
  [`cpu_request? int, cpu_unit`], [processeur réservé],
  [`cpu_limit? int, cpu_unit`], [processeur maximal],
  [`min_replicas? int`], [borne basse de la mise à l'échelle],
  [`max_replicas? int`], [borne haute ; le dimensionnement retient cette
    valeur],
  [`cpu_threshold? int`], [seuil d'utilisation du processeur, en %],
  [`memory_threshold? int`], [seuil d'utilisation de la mémoire, en %],
)

- Une réservation #doit être inférieure ou égale à sa limite
  (#code("E014")).
- `min_replicas` et `max_replicas` vont ensemble (#code("E006")), avec
  1 ≤ `min_replicas` ≤ `max_replicas` (#code("E016")).

== Sondes, métriques et journaux

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`health_check? string { … }`], [sonde de santé ; le sujet est le chemin
    HTTP sondé. Champs `interval? int` (défaut 30), `timeout? int` (défaut 5),
    `retries? int` (défaut 3). Un `timeout` qui n'est pas inférieur à
    l'`interval` donne #code("W011")],
  [`metrics? metrics_provider { … }`], [point de collecte ; le sujet est le
    collecteur (`prometheus`). Champs `path string` et `port? int`],
  [`log_format? log_format`], [`json` · `text` (défaut)],
  [`log_level? name`], [niveau de journalisation ; défaut `info`],
)

== Exemple

D'après `examples/enterprise-stack/web_api.loaf` :

```loaf
service web_api {
  runtime http.
  replicas 3.
  memory_request 256, mi.
  memory_limit 512, mi.
  cpu_limit 1, core.
  min_replicas 3.
  max_replicas 10.
  cpu_threshold 70.

  artifact "./bin/web_api" {
    sha256 "0000000000000000000000000000000000000000000000000000000000000000".
    format native.
    arch amd64.
  }

  port 8080 { protocol tcp. }
  environment "LOG_DIR", "/var/log/web_api".

  health_check "/health" {
    interval 10.
    timeout 3.
  }
  metrics prometheus { path "/metrics". }
  log_format json.
}
```

= Capacités, providers et consommations <capacites>

#stable

Une #terme[capacité] est un service générique qu'une application consomme
sans en choisir l'implémentation : une base de données, un cache. Un
#terme[provider] est un service qui fournit une capacité ; il se décrit par un
manifeste `service` ordinaire, et en ajouter un ne demande pas de recompiler
Hamac.

== Provider

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`capability? name`], [la capacité fournie],
  [`input* name => text`], [entrées : valeurs propres à chaque instance,
    engendrées une fois par consommation : `input password, gen(alnum, 32).`],
  [`readiness* [text]`], [commande de disponibilité, exécutée dans
    l'instance : `readiness ["pg_isready", "-U", input(user)].`],
  [`readiness_interval? int`], [délai entre deux essais ; défaut 5],
  [`readiness_timeout? int`], [délai maximal ; défaut 30],
)

`readiness_interval` ou `readiness_timeout` sans commande `readiness` donne
#code("E006"). Dans les champs du provider, `input(x)` désigne la valeur de
l'entrée `x` de l'instance, `instance(name)` son nom et `consumer(name)` le nom
du consommateur (@rendus).

== Contrats des capacités <contrats>

Le *contrat* d'une capacité est la liste des attributs qu'en offre tout
provider. Le vocabulaire déclare un bloc par contrat ; un provider le remplit
dans un bloc de même nom, sous son propre nom.

#tableau((auto, 1fr),
  [Contrat], [Attributs],
  [`database`], [`host text`, `port int`, `user text`, `password text`,
    `dbname text`],
  [`cache`], [`host text`, `port int`, `password text`],
)

Un service qui fournit `database` (resp. `cache`) #doit remplir le bloc de ce
contrat, et un bloc de contrat n'est admis que pour un service qui fournit la
capacité correspondante (#code("E024")). Une capacité qui n'a pas de contrat
dans le vocabulaire peut être déclarée et consommée, mais n'offre aucun
attribut aux gabarits de ses consommateurs.

Le provider PostgreSQL de `providers/postgresql.loaf` :

```loaf
service postgresql {
  runtime http.
  capability database.
  input user, gen(alpha, 12).
  input password, gen(alnum, 32).
  input dbname, cat(consumer(name), "_db").
  readiness ["pg_isready", "-U", input(user)].
  readiness_interval 5.
  readiness_timeout 30.
  environment "POSTGRES_USER", input(user).
  environment "POSTGRES_PASSWORD", input(password).
  environment "POSTGRES_DB", input(dbname).

  artifact "postgres:15-alpine" {
    sha256 "0000000000000000000000000000000000000000000000000000000000000000".
    format oci_image.
  }

  port 5432 { protocol tcp. }
}

database postgresql {
  host instance(name).
  port 5432.
  user input(user).
  password input(password).
  dbname input(dbname).
}
```

== Consommations <consumes>

Un service déclare chacune de ses dépendances par un sous-bloc `consumes`,
dont le sujet est un nom local au service. Une consommation de service
déclare aussi le flux réseau correspondant (@flux).

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`capability? name`], [dépendance envers une capacité, résolue vers un
    provider],
  [`service? service`], [dépendance envers un service nommé de l'ensemble],
  [`inject* string => text`], [injections : variables d'environnement du
    consommateur, construites à partir de ce qu'offre le service consommé],
  [`mode? consume_mode`], [#experimental `request` (défaut) : le
    consommateur ouvre les connexions ; `push` : le service consommé émet,
    le consommateur reçoit],
)

Une consommation nomme exactement un de `capability` et `service`
(#code("E013")).

*Provider retenu.* Hamac calcule le champ `provider` de chaque consommation,
qu'aucun manifeste n'écrit. Pour une consommation de service, c'est le service
nommé. Pour une consommation de capacité, c'est le provider que la stack
impose (@stack), sinon le seul service de l'ensemble qui fournit cette
capacité. En présence d'une stack, une capacité sans provider, ou fournie par
plusieurs services sans choix de la stack, est une erreur (#code("E023")).

*Ce que lisent les gabarits.* Dans un sous-bloc `consumes`, `~` désigne la
consommation. Elle offre aux gabarits de ses injections :

#tableau((auto, 1fr),
  [Attribut], [Valeur],
  [`~.database.user`, `~.database.host`…], [l'attribut du contrat `database`
    rempli par le provider retenu, pour une consommation de cette capacité],
  [`~.cache.password`…], [de même pour `cache`],
  [`~.host`], [le nom d'hôte du service consommé, pour une consommation de
    service],
  [`~.port`], [le premier port, c'est-à-dire le plus petit, que déclare le
    service consommé],
)

Le langage vérifie chaque attribut contre la déclaration du contrat
(#code("L001") pour un attribut que le contrat ne déclare pas). Une injection
dont un attribut n'a pas de valeur, par exemple parce que l'ensemble ne
contient aucun provider de la capacité, est refusée (#code("L014")) : un
service qui consomme une capacité se valide avec ses providers.

Deux consommations, extraites de `examples/hr-stack/` :

```loaf
service hr_api {
  consumes db {
    capability database.
    inject "DATABASE_URL",
           fmt("postgresql://{~.database.user}:{~.database.password}@{~.database.host}:{~.database.port}/{~.database.dbname}").
  }
}

service payroll_report {
  consumes api {
    service hr_api.
    inject "HR_API_URL", fmt("http://{~.host}:{~.port}").
  }
}
```

Le gabarit de `hr_api` est rempli par le modèle avec les attributs du
provider retenu : `{~.database.user}` devient `input(user)` de `postgresql`,
que Hamac remplace au déploiement par l'identifiant engendré pour l'instance
de `hr_api`.

`hamac resolve` montre ce câblage. Avec `--seed`, réservé aux tests, les
valeurs tirées au hasard sont reproductibles :

```
Providers to instantiate:
  postgresql-hr-api-db (postgres:15-alpine@sha256:54e0dd8e…)
    env: POSTGRES_DB=hr_api_db
    env: POSTGRES_PASSWORD=z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs
    env: POSTGRES_USER=pottxvuimhan

Wiring:
  hr_api.db -> postgresql
    inject: DATABASE_URL=postgresql://pottxvuimhan:z72SYu7MDwnY8NCONRJsMfb5QNVfDvXs@postgresql-hr-api-db:5432/hr_api_db
  payroll_report.api -> hr_api (service)
    inject: HR_API_URL=http://hr-api:8080
```

Le nom d'hôte de l'instance, `postgresql-hr-api-db`, réunit le provider, le consommateur
et la consommation ; un second consommateur de `database` recevrait sa
propre instance, avec d'autres identifiants.

= Données : stockage, sauvegarde, secrets <donnees>

#experimental

#regle[
  *Stockage objet par défaut.* Les fichiers, pièces jointes et artefacts d'un
  service #devrait être placés dans un stockage objet, consommé comme une
  capacité (@capacites). Un service sans état local peut être déplacé sans
  contrainte. `storage` décrit uniquement les données qui doivent rester sur
  un système de fichiers.
]

== Volumes et sauvegarde

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`storage* name { … }`], [volume de système de fichiers ; le sujet est son
    nom],
  [#h(1em)`mount string`], [point de montage, chemin absolu (#code("E031"))],
  [#h(1em)`class storage_class`], [`ephemeral` : perdu au redémarrage ;
    `local` : stocké sur le nœud, perdu avec lui ; `replicated` : le service
    réplique lui-même ses données entre ses répliques, comme PostgreSQL sous
    Patroni],
  [#h(1em)`size? int, size_unit`], [taille ; obligatoire hors `ephemeral`
    (#code("E032"))],
  [#h(1em)`rebuild? rebuild`], [pour `local` : `from_backup` · `from_object` ·
    `from_replica` · `none`, la façon de reconstruire le volume sur un autre
    nœud. Avec `none`, le service n'est pas relocalisable : le planner ne le
    déplace pas et le signale],
  [`backup? string { … }`], [politique de sauvegarde ; le sujet est la
    planification, une expression cron],
  [#h(1em)`retention* retention_period => int`], [nombre d'instantanés
    conservés par période : `hourly` · `daily` · `weekly` · `monthly` ·
    `yearly`],
  [#h(1em)`pre* [string]`, `post* [string]`], [commandes exécutées dans le
    service avant et après l'instantané, pour sa cohérence],
  [#h(1em)`verify? verify`], [`none` (défaut) · `restore_test` : restauration
    vérifiée à chaque cycle],
)

Un volume `local` sans `rebuild`, dans un service sans `backup`, est refusé
(#code("E033")) : le sort de ses données en cas de perte du nœud doit être
déclaré.

La classe d'un volume dit ce qu'il advient de ses données quand le nœud qui
porte le service disparaît :

#tableau((auto, 1fr),
  [Volume], [Après la perte du nœud],
  [`ephemeral`], [rien à reconstruire : le volume repart vide sur un autre
    nœud],
  [`local`, `rebuild from_backup`], [le volume est restauré depuis la
    dernière sauvegarde du service],
  [`local`, `rebuild from_replica`], [le volume est recopié depuis une autre
    réplique du service],
  [`local`, `rebuild from_object`], [le volume est reconstruit depuis le
    stockage objet du service],
  [`local`, `rebuild none`], [les données sont perdues ; le service reste sur
    son nœud tant que celui-ci existe],
  [`replicated`], [le service reconstruit lui-même la réplique perdue à
    partir des autres],
)

Dans l'exemple (@exemple), le cache de `payroll_report` est `local` avec
`rebuild none` : il se recalcule, sa perte ne coûte que du temps.

== Secrets <secrets>

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`secret* name { … }`], [secret du service ; le sujet est son nom, que
    désigne `secret(x)`],
  [#h(1em)`ref? string`], [référence d'un secret existant,
    `<backend>:<chemin>[#<clé>]` (#code("E007") sans `:`) ; backends
    `openbao` et `sops`],
  [#h(1em)`generate? gen_kind, int`], [secret créé par Hamac au premier
    déploiement et stocké dans le backend par défaut : sorte de caractères
    (`alpha` · `alnum`) et longueur],
  [#h(1em)`rotate? int, time_unit`], [période de rotation ; absent : pas de
    rotation automatique],
  [#h(1em)`as? secret_as`], [`env` (défaut) : variable d'environnement ;
    `file` : fichier en lecture seule sous `/run/secrets/<nom>`],
)

- Un secret a exactement un de `ref` et `generate` (#code("E034")).
- `secret(x)` dans une variable d'environnement ou une injection, sans secret
  `x` déclaré par le service : #code("E020").
- Une variable d'environnement dont le nom se termine par `PASSWORD`, `TOKEN`,
  `SECRET` ou `_KEY` et dont la valeur est une chaîne littérale non vide
  donne #code("W012") : un secret se déclare par `secret`.

== Exemple

Extrait d'un service de forge logicielle :

```loaf
service forge {
  environment "SMTP_PASSWORD", secret(smtp_password).
  environment "SESSION_KEY", secret(session_key).

  secret smtp_password { ref "openbao:kv/mail/smtp#password". }
  secret session_key {
    generate alnum, 64.
    rotate 90, d.
    as file.
  }

  storage repositories {
    mount "/data/git".
    class local.
    size 50, gi.
    rebuild from_backup.
  }
  storage work {
    mount "/tmp/work".
    class ephemeral.
  }
  backup "*/30 * * * *" {
    retention hourly, 24.
    retention daily, 7.
    retention weekly, 4.
    pre ["forgejo", "dump", "--type", "tar"].
    verify restore_test.
  }
}
```

= Patrons <pattern>

Un #terme[patron] fixe les choix de sécurité d'une organisation : un treillis
de sensibilité, des zones, des exigences d'assurance, des contraintes sur la
topologie. Hamac n'en impose aucun ; des organisations aux besoins différents
utilisent le même outil avec des patrons différents.

== Un patron est un module

Un patron est le bloc `pattern` d'un module LOAF, qui en porte la version. La
stack le charge par `use` (@modules) ; un patron qui en complète un autre
charge le module de celui-ci. Les patrons de l'ensemble, c'est-à-dire ceux
des modules que ses fichiers chargent, composent le treillis de la stack.

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`levels* [name]`], [les niveaux, du moins au plus sensible (@treillis)],
  [`category* name`], [les catégories de besoin d'en connaître ; des
    catégories sans aucun niveau donnent #code("E006")],
  [`role* name`], [les rôles que l'organisation attribue à ses utilisateurs,
    seuls exigibles par une route (@routes)],
  [`zone* name { … }`], [une zone (@treillis) : `level name`,
    `category* name`, `boundary? boundary` (défaut `firewall`, @frontieres)],
  [`assurance* name, axis => assurance_level`], [#experimental exigence
    d'assurance d'une zone sur un axe (@assurance)],
  [`constraint* name { … }`], [#experimental contrainte sur la topologie
    (@contraintes)],
  [`minimize* string { … }`, `maximize* string { … }`], [#experimental
    objectifs (@objectifs)],
)

Le patron de `examples/hr-stack/patterns/exemple_rh.loaf` :

```loaf
loaf 0.1.
module exemple_rh 1.0.0.
use hamac 0.2.

pattern exemple_rh {
  levels [public, internal, confidential].
  category rh; finance.
  role rh; comptable; admin.
  assurance rh, boot, measured_tpm2.
  assurance rh, physical, site.

  zone public { level public. }
  zone internal { level internal. }

  zone rh {
    level confidential.
    category rh; finance.
  }

  constraint one_level_per_host {
    description "Deux niveaux ne partagent jamais un noyau".
    violation "H : level_on(H, L1), level_on(H, L2), L1 != L2".
  }

  constraint stateful_quorum {
    description "Un service à état survit à la perte d'un domaine de panne".
    severity soft.
    violation "S : stateful(S), #count { D : on(S, H), failure_domain(H, D) } < 3".
  }

  minimize "1, H : used(H)" { priority 1. }
}
```

== Treillis et zones <treillis>

- `levels` donne les niveaux dans l'ordre, du moins au plus sensible : c'est un
  ordre total.
- Une #terme[étiquette] est un couple (niveau, ensemble de catégories), et
  (n#sub[1], C#sub[1]) ≤ (n#sub[2], C#sub[2]) si et seulement si
  n#sub[1] ≤ n#sub[2] et C#sub[1] ⊆ C#sub[2]. Cet ordre définit un treillis,
  celui du modèle Bell-LaPadula avec compartiments.
- Une #terme[zone] a un nom, une étiquette (son `level` et ses `category`) et
  une frontière. Son niveau et ses catégories #doit appartenir au treillis du
  patron (#code("E042")).

Une étiquette dit à la fois _à quel point_ une donnée est sensible (le
niveau) et _à qui_ elle est destinée (les catégories). L'ordre sert à deux
contrôles : un service ne lit que des zones d'étiquette inférieure ou égale à
la sienne (@flux), et un utilisateur ne lit une route que si son habilitation
domine l'étiquette de la route (@routes).

Avec le patron de l'exemple (@exemple), et deux zones `paie` et `dossiers`
ajoutées pour l'illustration :

#tableau((auto, auto, 1fr),
  [Zone], [Étiquette], [Comparaisons],
  [`public`], [(`public`, ∅)], [inférieure à toutes les autres],
  [`internal`], [(`internal`, ∅)], [`public` ≤ `internal` ≤ `rh`],
  [`paie`], [(`confidential`, {`finance`})], [≤ `rh` ; incomparable avec
    `dossiers`],
  [`dossiers`], [(`confidential`, {`rh`})], [≤ `rh` ; incomparable avec
    `paie`],
  [`rh`], [(`confidential`, {`rh`, `finance`})], [supérieure à toutes les
    autres],
)

`paie` et `dossiers` ont le même niveau, mais aucune des deux ne détient
toutes les catégories de l'autre : un service de `paie` ne lit pas un service
de `dossiers`, ni l'inverse. Un service de `rh`, qui détient les deux
catégories, lit les deux.

*Composition.* Quand l'ensemble contient plusieurs patrons, leurs niveaux
#doit être identiques, dans le même ordre (#code("E050")) ; leurs catégories
s'unissent. Un patron qui ne déclare pas de niveaux adopte ceux des autres.
Une zone définie par deux patrons avec des étiquettes ou des frontières
différentes donne #code("E051"). Le niveau d'une zone absent des niveaux
composés donne #code("E042").

Un patron qui en complète un autre :

```loaf
loaf 0.1.
module anssi_hygiene 1.0.0.
use hamac 0.2.

pattern anssi_hygiene {
  levels [public, default, internal, secure].

  constraint one_level_per_host {
    description "Deux niveaux ne partagent jamais un noyau".
    violation "H : level_on(H, L1), level_on(H, L2), L1 != L2".
  }
}
```

```loaf
loaf 0.1.
module anssi_renforce 1.0.0.
use hamac 0.2.
use anssi_hygiene 1.0.

pattern anssi_renforce {
  levels [public, default, internal, secure].
  category finance; rh.

  zone public { level public. }
  zone default { level default. }
  zone internal { level internal. }
  zone rh {
    level internal.
    category rh.
  }
  zone secure {
    level secure.
    boundary diode.
  }

  assurance internal, boot, confidential_vm.
  assurance internal, operator, secnumcloud.
  assurance secure, boot, measured_tpm2.
  assurance secure, physical, site.
}
```

*Zones par défaut.* Si aucun patron ne définit de zone, chaque niveau est une
zone de même nom. Sans patron, Hamac applique le patron intégré
`hamac-default` : les niveaux, et donc les zones, `public` < `default` <
`internal` < `secure`, sans catégorie ni contrainte.

== Frontières de zone <frontieres>

#tableau((auto, 1fr),
  [`boundary`], [Sens],
  [`firewall` (défaut)], [filtrage avec état ; les flux déclarés ouvrent des
    connexions],
  [`diode`], [passerelle unidirectionnelle, du bas vers le haut : aucune
    donnée ne sort de la zone vers une zone moins sensible],
)

À travers une diode, aucune requête ne peut recevoir de réponse. Une
consommation entre deux zones dont l'une a une frontière `diode` #doit donc
être de mode `push` (@flux) : le service consommé émet ce que le
consommateur reçoit (réplication, flux d'événements, fichiers).

Une zone derrière une diode a son propre plan de contrôle, puisqu'un
contrôleur extérieur n'en recevrait pas les rapports. Hamac produit une
infrastructure par enclave. Les manifestes signés entrent par la diode ;
l'état de l'enclave n'en sort que par une déclassification explicite.

== Axes d'assurance <assurance>

#experimental

Trois axes à valeurs ordonnées, fixés par le vocabulaire (énumérations `axis`
et `assurance_level`) :

#tableau((auto, 1fr),
  [Axe], [Niveaux, du plus faible au plus fort],
  [`boot`], [`none` < `provider_vtpm` < `confidential_vm` < `measured_tpm2`],
  [`operator`], [`any` < `eu` < `secnumcloud` < `self`],
  [`physical`], [`third_party` < `dedicated_rack` < `site`],
)

Un nœud offre un niveau par axe, déclaré par l'inventaire ou par le profil qui
l'a installé (@profil). Une zone ou un service exige un minimum. Un placement
est admissible si et seulement si, sur chaque axe, le niveau offert est au
moins égal au niveau exigé ; un axe sans exigence n'impose rien.

Dans un patron, `assurance rh, boot, measured_tpm2.` exige ce niveau de la
zone `rh`. Un niveau qui n'appartient pas à son axe donne #code("E007") ; une
zone que le patron ne définit pas, alors qu'il en définit, donne
#code("E042").

#note[
  `provider_vtpm` et `confidential_vm` se distinguent sur un point : dans une
  machine virtuelle classique, c'est l'hyperviseur du fournisseur qui mesure
  le démarrage ; dans une machine virtuelle confidentielle (AMD SEV-SNP,
  Intel TDX), le processeur l'atteste et la mesure est opposable à
  l'hyperviseur.
]

== Contraintes <contraintes>

#experimental

Le #terme[planificateur] (`hamac plan`) choisit la topologie d'une stack :
il place chaque réplique de chaque service à déployer sur un nœud de sa zone,
dans la capacité des nœuds et selon le placement que les services demandent
(@placement), puis optimise. Il résout pour cela un programme en
#terme[ASP] (_Answer Set Programming_), dans le langage de clingo 5, qui
s'ajoute à la forme ASP de l'ensemble de fichiers (définie par la
spécification de LOAF) : chaque fait de l'ensemble y est un atome, par
exemple `service_zone(hr_api, rh)`. Les contraintes et les objectifs des
patrons s'écrivent dans ce langage, sur les atomes de l'ensemble et sur les
prédicats que publie le planificateur.

*Prédicats publiés.* Un service, une zone ou un niveau y est désigné par son
nom tel que l'écrivent les fichiers LOAF ; un nœud candidat par le triplet
`(Z, A, K)`, sa zone, son architecture et son numéro parmi les nœuds de
cette zone et de cette architecture, à partir de 1, les nœuds utilisés
portant les premiers numéros.

#tableau((auto, 1fr),
  [Prédicat], [Sens],
  [`deployed(S)`], [`S` est un service à déployer : un service que nomme la
    stack, ou, sans stack, un service qui ne fournit pas de capacité],
  [`zone_of(S, Z)`], [sa zone (`default` s'il n'en déclare pas)],
  [`replicas(S, N)`], [son nombre de répliques (`max_replicas` s'il est
    dimensionné automatiquement)],
  [`memory(S, M)`, `cpu(S, C)`], [la demande d'une réplique : sa limite de
    mémoire en Mi (défaut 256), de processeur en millicœurs (défaut 500)],
  [`stateful(S)`], [`S` a un volume `local` ou `replicated`],
  [`replica(S, I)`], [la réplique `I` de `S`, `I` de 1 à `N`],
  [`arch_of(S, A)`], [l'artefact de `S` s'exécute sur l'architecture `A`],
  [`host(H)`, `host_zone(H, Z)`, `host_arch(H, A)`], [un nœud candidat, sa
    zone et son architecture],
  [`failure_domain(H, D)`], [le domaine de panne d'un nœud ; un nœud
    candidat est son propre domaine],
  [`place(S, I, H)`], [la réplique `I` de `S` est sur le nœud `H`],
  [`on(S, H)`], [au moins une réplique de `S` est sur `H`],
  [`used(H)`], [le nœud `H` porte au moins une réplique],
  [`level_on(H, L)`], [une zone de niveau `L` a une réplique sur `H`],
)

*Contrainte.* Un sous-bloc `constraint` d'un patron, dont le sujet est un
nom unique dans le patron.

#tableau((auto, 1fr),
  [Déclaration], [Sens et défaut],
  [`description? string`], [texte libre],
  [`severity? severity`], [`hard` (défaut) : toute topologie retenue la
    satisfait ; `soft` : chaque violation est une pénalité],
  [`weight? int`, `priority? int`], [poids et priorité de la pénalité d'une
    contrainte `soft`, défaut 1 (@objectifs)],
  [`violation string`], [les violations de la contrainte, sous la forme
    `termes : corps`],
)

`violation` a la forme d'un élément d'agrégat de clingo : `termes` est une
suite de termes séparés par des virgules, éventuellement vide, `corps` un
corps de règle. Chaque instance close de `termes` qui satisfait `corps` est
une violation, dont `termes` est le #terme[témoin]. Une contrainte est
satisfaite quand elle n'a aucune violation. La violation est elle-même une
chaîne LOAF : ses guillemets internes s'écrivent `\"`.

```loaf
constraint one_level_per_host {
  description "Deux niveaux ne partagent jamais un noyau".
  violation "H : level_on(H, L1), level_on(H, L2), L1 != L2".
}

constraint stateful_quorum {
  description "Un service à état survit à la perte d'un domaine de panne".
  severity soft.
  violation "S : stateful(S), #count { D : on(S, H), failure_domain(H, D) } < 3".
}
```

Le planificateur rapporte chaque violation d'une contrainte `soft` de la
topologie retenue par un avertissement, avec son témoin. Quand aucune
topologie ne satisfait les contraintes `hard`, il échoue en donnant les
violations de la topologie qui en compte le moins, avec leurs témoins.

Une violation sans ses deux-points, une erreur de syntaxe, une variable non
sûre (qui n'apparaît dans aucun atome positif du corps) ou un prédicat
qu'aucune règle ne définit donnent #code("E052"), à la déclaration. Ce
contrôle ne porte que sur un ensemble de fichiers sans autre erreur.

== Objectifs <objectifs>

#experimental

`minimize` et `maximize` déclarent un objectif ; le sujet a la forme
`poids, termes : corps` d'un élément d'agrégat `#minimize` ou `#maximize`
de clingo : chaque instance close de `termes` qui satisfait `corps` compte
pour `poids`, qui #doit être un entier, une fois par instance. `termes` est
facultatif. Le champ `priority? int` (défaut 1) en donne la priorité. Les
mêmes fautes que pour une violation donnent #code("E052").

```loaf
minimize "1, H : used(H)" { priority 1. }
```

L'optimisation est lexicographique par priorité, la plus grande d'abord ; à
priorité égale, les poids des objectifs et des pénalités des contraintes
`soft` s'additionnent, un objectif `maximize` comptant ses poids en négatif.
Après les objectifs des patrons, de priorité 1 ou plus, le planificateur
minimise le nombre de nœuds, à la priorité 0.

= Sécurité, placement et exposition d'un service <securite>

== Zone et flux <flux>

#tableau((auto, 1fr),
  [Déclaration], [Sens et contrôles],
  [`zone? name`], [la zone du service, définie par les patrons de l'ensemble
    (#code("E042") sinon) ; défaut `default`],
)

Chaque consommation de service (`consumes … { service t. }`) déclare un flux
réseau, du consommateur vers le service consommé.

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
  (@frontieres), le flux #doit être de mode `push` (#code("E041")).

Dans l'exemple (@exemple), si `hr_api` (zone `rh`) consommait le portail
(zone `public`), il lirait vers le bas, ce que le treillis permet :

```loaf
service hr_api {
  consumes site { service portal. }
}
```

Le planificateur ouvre alors ce seul flux, et refuse le reste :

```
DENY public -> rh (no read up)
ALLOW rh -> public (hr_api -> portal)
Stateful: replies to an allowed connection pass.
```

Le flux inverse, `portal` qui consommerait `hr_api`, est refusé dès la
validation :

```
portal.loaf:19:3: [E040] portal (zone public) cannot consume hr_api (zone rh):
opening a connection to a more sensitive zone is a read up, forbidden by the
Bell-LaPadula model. […]
```

Écrire vers le bas, c'est-à-dire qu'un service sensible envoie des données à
une zone moins sensible, ne relève pas du réseau : une réponse à une connexion
autorisée passe, et ce qu'elle contient est l'affaire de l'application et du
contrôle d'accès de ses routes.

== Routes <routes>

Un service HTTP déclare l'autorisation de ses routes, vérifiée en bordure
avant que la requête ne l'atteigne.

#tableau((auto, 1fr),
  [Déclaration], [Sens et contrôles],
  [`route* string { … }`], [le sujet est le chemin ; `*` en fin de segment
    couvre tout suffixe (`/salary/*`). Pas d'autre joker],
  [#h(1em)`method* string`], [méthodes HTTP ; aucune : toutes],
  [#h(1em)`public`], [aucun jeton exigé. Exclusif avec les trois champs
    suivants (#code("E043"))],
  [#h(1em)`classification? name`], [niveau du treillis ; le niveau
    d'habilitation du sujet #doit lui être supérieur ou égal],
  [#h(1em)`category* name`], [le sujet #doit détenir chacune de ces
    catégories (besoin d'en connaître)],
  [#h(1em)`required_clearance* name`], [rôles ; le sujet #doit en détenir au
    moins un. Un rôle qu'aucun patron de l'ensemble ne déclare (`role`) donne
    #code("E045")],
)

*Sémantique.* Une requête vers une route est autorisée si et seulement si le
jeton présenté établit, pour le sujet :

#align(center)[
  niveau ≥ `classification` #h(4pt) *et* #h(4pt) `category` ⊆ catégories du
  sujet #h(4pt) *et* #h(4pt) (`required_clearance` vide *ou* un rôle du
  sujet ∈ `required_clearance`).
]

Dès qu'un service déclare une route, les chemins qu'aucune route ne couvre
sont refusés. Si plusieurs routes couvrent un chemin, la plus spécifique
s'applique : préfixe le plus long, puis méthodes explicites.

*Cohérence avec la zone.* Un service qui déclare des routes #doit avoir une
zone (#code("E006")). La classification d'une route #doit être un niveau du
treillis (#code("E042")) et ne #doit-pas dépasser le niveau de la zone du
service ; ses catégories #doit être incluses dans celles de la zone
(#code("E044")). Un service ne sert donc pas de données plus sensibles que sa
zone.

*Mise en œuvre.* Le provider d'autorisation traduit les routes en règles
Biscuit : une comparaison d'entiers pour le niveau, une vérification par
catégorie et une jointure pour les rôles. La vérification a lieu en bordure,
dans Sozu. Il revient au provider d'établir que cette traduction accepte
exactement les accès permis par le treillis.

Les routes de `examples/hr-stack/hr-api.loaf`, dans la zone `rh` du patron
`exemple_rh` :

```loaf
service hr_api {
  zone rh.

  route "/health" { public. }

  route "/employees/*" {
    method "GET".
    classification internal.
    category rh.
    required_clearance rh; admin.
  }

  route "/employees/salaries" {
    classification confidential.
    category rh; finance.
    required_clearance comptable; admin.
  }
}
```

Avec ces routes, et trois utilisateurs :

#tableau((auto, auto, auto, auto),
  [Utilisateur], [Habilitation], [`GET /employees/42`], [`GET /employees/salaries`],
  [Alice], [`internal`, {`rh`}, rôle `rh`], [autorisée], [refusée : niveau
    et catégorie `finance` manquants],
  [Bruno], [`confidential`, {`rh`, `finance`}, rôle `comptable`], [refusée :
    ni `rh` ni `admin`], [autorisée],
  [Chloé], [`confidential`, {`rh`, `finance`}, rôle `admin`], [autorisée],
    [autorisée],
)

`/employees/salaries` est couvert par les deux routes ; la plus spécifique,
`/employees/salaries`, s'applique seule. Bruno lit donc les salaires sans
pouvoir consulter la fiche d'un salarié : chaque route donne ses propres conditions, et
aucune n'hérite d'une autre. `/health` est public : aucun jeton n'est demandé.
Un chemin qu'aucune route ne couvre, `/admin` par exemple, est refusé à tous.

== Placement <placement>

#experimental

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`need* name`], [capacités que le nœud #doit offrir, telles que
    l'inventaire les déclare (`public_ipv4`, `ssd`)],
  [`assurance* axis => assurance_level`], [minimum par axe (@assurance), qui
    s'ajoute à l'exigence de la zone ; un niveau hors de son axe donne
    #code("E007")],
  [`spread? spread`], [répartition des répliques : `none` (défaut) · `host` ·
    `failure_domain`],
  [`affinity* service`, `anti_affinity* service`], [services à rapprocher ou
    à séparer],
)

Le vocabulaire ne prévoit pas de placement par nom d'hôte.

```loaf
service forge {
  need public_ipv4; ssd.
  assurance boot, measured_tpm2.
  assurance physical, site.
  spread failure_domain.
  anti_affinity postgresql.
}
```

== Exposition <exposition>

#experimental

Une exposition publie un port du service en bordure. Sans flux déclaré, c'est
la seule façon de rendre un service joignable depuis l'extérieur de sa zone.

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`exposure* string { … }`], [le sujet est le nom DNS public],
  [#h(1em)`port int`], [un port déclaré par `port` (#code("E035"))],
  [#h(1em)`path_prefix? string`], [défaut `/`],
  [#h(1em)`protocol? exposure_protocol`], [`http` (défaut) · `tcp`],
  [#h(1em)`tls? tls`], [`acme` (défaut) · `internal` · `passthrough`],
)

Un service exposé en `http` qui déclare des routes voit chaque requête
validée par la bordure selon @routes.

```loaf
service forge {
  port 3000 {}
  port 2222 {}

  exposure "forge.example.org" {
    port 3000.
    tls acme.
  }
  exposure "ssh.forge.example.org" {
    port 2222.
    protocol tcp.
    tls passthrough.
  }
}
```

= Bundle <bundle>

#stable

Un bundle est une brique réutilisable d'un profil de provisioning : un
répertoire qui contient le manifeste `bundle.loaf` et un gabarit Jinja2 de
fragment cloud-init. La spécification du provisioning
(`doc/typst/provisioning.typ`) décrit où Hamac cherche les bundles, le
rendu des gabarits et la fusion des fragments.

```
templates/bundles/dev_workstation/
├── bundle.loaf
├── cloud-init.yaml.j2           # gabarit par défaut
└── cloud-init.<family>.yaml.j2  # variante pour une famille d'OS (optionnel)
```

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`version? string`], [version du bundle ; défaut `0.1.0`],
  [`param* name { … }`], [paramètre accepté ; le sujet est son nom],
  [#h(1em)`type param_type`], [`string` · `int` · `bool` · `list_string` ·
    `list_int` · `object`],
  [#h(1em)`required`], [le profil #doit en donner la valeur ; sinon le rendu
    échoue],
  [`depends_on* bundle`], [bundles à appliquer avant celui-ci : un profil
    qui l'applique les liste avant lui (#code("E012"))],
  [`lifecycle? lifecycle`], [#experimental `install` (défaut) · `converge`],
)

Extrait de `templates/bundles/dev_workstation/bundle.loaf` :

```loaf
bundle dev_workstation {
  version "0.1.0".
  description "Poste de dev minimal : utilisateur sudo, SSH, docker, dotfiles optionnels".

  param username {
    type string.
    required.
  }
  param ssh_public_keys { type list_string. }
  param timezone { type string. }
}
```

*Cycle de vie.* `lifecycle install` : le bundle est appliqué une fois, au
premier démarrage. `lifecycle converge` : il est appliqué à l'installation,
puis en cours de vie par l'agent. Un bundle `converge` #doit décrire un état à
atteindre ; il est appliqué de façon idempotente, et tout écart constaté est
signalé comme une dérive. Ce mode permet de prendre en charge une machine que
Hamac n'a pas installée.

= Profil de provisioning <profil>

#stable

Un profil de provisioning décrit le système installé sur une machine : une
image d'OS et une liste de bundles paramétrés. Il ne nomme aucune machine ; un
nœud d'infrastructure le désigne par son nom (@infrastructure). La
spécification du provisioning décrit comment Hamac l'applique : démarrage
PXE, rendu et fusion du cloud-init, écriture de l'image sur le disque.

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`os string { … }`], [image d'OS (ci-dessous) ; le sujet est son
    identifiant, à usage humain],
  [`bundles* [bundle]`], [les bundles appliqués, dans l'ordre ; un bundle
    listé deux fois, ou avant un bundle dont il dépend (`depends_on`), donne
    #code("E012")],
  [`bundle* bundle { param* name { … } }`], [paramètres d'un bundle de la
    liste : chaque `param` a soit `value? text` (paramètre scalaire), soit
    `items* [text]` (paramètre liste), exactement un des deux
    (#code("E007")). Des paramètres pour un bundle que `bundles` ne liste pas
    donnent #code("E007")],
  [`cloud_init_extra? string`], [fragment cloud-init, en YAML, fusionné
    après ceux des bundles],
  [`assurance* axis => assurance_level`], [#experimental niveaux d'assurance
    qu'offre une machine installée par ce profil (@assurance)],
)

Un profil sans bundle ni `cloud_init_extra` ne change rien à l'image installée
(#code("W013")). Un profil nomme ses bundles : il se valide avec eux, dans le
même ensemble.

Le sous-bloc `os` porte :

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`url string`], [URL de l'image de référence, consommée telle quelle par
    les machines virtuelles],
  [`sha256 string`], [empreinte de l'image, 64 caractères hexadécimaux
    (#code("E011"))],
  [`format os_format`], [`qcow2` · `raw` · `iso` · `netinstall` ;
    `netinstall` : noyau et initrd d'installation, suivis d'une installation
    automatisée],
  [`arch? arch`], [architecture de l'image ; défaut `amd64`],
  [`family? name`], [famille d'OS ; défaut `debian`. Choisit la variante du
    gabarit cloud-init des bundles],
  [`raw_zst_url? string`], [image disque brute compressée en zstd, dérivée de
    `url`, pour l'écriture sur une machine physique],
  [`raw_zst_sha256? string`], [empreinte de `raw_zst_url`],
  [`bmap_url? string`], [carte des blocs utiles (`bmaptool create`) associée
    à `raw_zst_url`],
)

D'après `provisioning-profiles/dev-workstation-demo.loaf` :

```loaf
provisioning_profile dev_workstation_demo {
  cloud_init_extra "{runcmd: [systemctl enable --now ssh]}".

  os "debian-12-amd64-genericcloud" {
    url "https://cdimage.debian.org/cdimage/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2".
    sha256 "0000000000000000000000000000000000000000000000000000000000000000".
    format qcow2.
    family debian.
  }

  bundles [dev_workstation].

  bundle dev_workstation {
    param username { value "devuser". }
    param timezone { value "Europe/Paris". }
    param ssh_public_keys {
      items ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEXAMPLE example@hamac"].
    }
  }
}
```

= Infrastructure <infrastructure>

#stable

Une infrastructure décrit une topologie : des nœuds, des segments réseau et le
filtrage entre zones. Le planner de Hamac la produit à partir d'une stack ; un
opérateur peut la relire, la figer ou la modifier. Une infrastructure modifiée
est revérifiée contre les patrons de la stack avant tout déploiement.

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`backend backend`], [`physical` · `incus` · `qemu` · `kubernetes` ·
    `docker_compose`],
  [`min_nodes? int`, `total_ram? int, size_unit`, `total_cpu? int`],
    [exigences minimales],
  [`node* name { … }`], [un rôle de nœud ; le sujet est le rôle],
  [#h(1em)`zone? name`], [la zone que ces nœuds accueillent ; défaut : le
    rôle],
  [#h(1em)`arch? arch`], [architecture du processeur ; défaut `amd64`. Celle
    de l'image d'OS de son profil (#code("E009"))],
  [#h(1em)`count? int`], [nombre de nœuds ; défaut 1],
  [#h(1em)`ram? int, size_unit`, `cpu? int`], [capacité de chaque nœud],
  [#h(1em)`boot? assurance_level`], [niveau de l'axe `boot` (#code("E007")
    pour un niveau d'un autre axe)],
  [#h(1em)`os_image? string`, `os_sha256? string`], [image d'OS du nœud,
    ignorée quand le nœud a un profil],
  [#h(1em)`isolated`], [nœud réservé à une zone],
  [#h(1em)`provisioning_profile? provisioning_profile`], [profil qui installe
    le nœud (@profil)],
  [`segment* name { cidr string. vlan? int. }`], [segment réseau],
  [`allow* name, name, service, service`], [ouvre les connexions de la zone
    source vers la zone destination, pour le flux déclaré (consommateur,
    service consommé) qui le justifie],
  [`deny* name, name`], [refus explicite d'une zone source vers une zone
    destination],
  [`deny_reason* name, name => string`], [motif d'un refus],
  [`warning* string`], [avertissements du planner],
  [`certificate? string`], [#experimental référence au certificat de
    résolution],
)

Le filtrage est avec état. Une règle `allow` nomme toujours le flux déclaré
qui la justifie ; tout trafic entre zones qu'aucune règle n'ouvre est refusé.

```loaf
infrastructure si_exemple {
  backend incus.
  min_nodes 3.
  total_ram 48, gi.
  total_cpu 12.

  node worker {
    zone internal.
    count 3.
    ram 16, gi.
    cpu 4.
    boot confidential_vm.
  }

  segment internal {
    cidr "10.0.2.0/24".
    vlan 20.
  }

  allow internal, default, forge, postgresql_ha.
  deny default, internal.
  deny_reason default, internal, "no read up".
}
```

= Stack <stack>

#stable

Une stack réunit les services à déployer ensemble. Ses patrons sont ceux des
modules qu'elle charge par `use` (@pattern) ; sans patron, `hamac-default`
s'applique.

#tableau((auto, 1fr),
  [Déclaration], [Sens, défaut et contrôles],
  [`accept_experimental`], [supprime #code("W001") pour tout l'ensemble],
  [`service* service { … }`], [un service déployé par la stack ; un service
    de l'ensemble que la stack ne nomme pas est un provider (@capacites)],
  [#h(1em)`replicas? int`], [remplace le `replicas` du service],
  [#h(1em)`consumes* name { provider service. }`], [impose le provider d'une
    consommation du service. La consommation #doit exister
    (#code("E022")), et le provider imposé #doit fournir la capacité
    consommée (#code("E023"))],
  [`infrastructure? infrastructure`], [infrastructure imposée : elle
    #doit offrir à chaque service un nœud de sa zone et d'une de ses
    architectures (#code("E046")) ; absente :
    calculée par le planner],
)

Une stack sans service donne #code("W002").

L'ensemble de l'exemple réunit cette stack, le service `forge` des sections
précédentes, les patrons `anssi_hygiene` et `anssi_renforce` (@treillis),
l'infrastructure `si_exemple` (@infrastructure) et trois providers :
`postgresql`, un second provider de `database` nommé `postgresql_ha`, et un
provider de `cache`.

```loaf
loaf 0.1.
use hamac 0.2.
use anssi_renforce 1.0.

stack si_exemple {
  description "Forge logicielle".
  accept_experimental.

  service forge {
    replicas 2.
    consumes db { provider postgresql_ha. }
  }

  infrastructure si_exemple.
}
```

Deux services de l'ensemble fournissent `database` : sans le choix de la
stack, la consommation `db` de `forge` donnerait #code("E023").

= Validation <validation>

== Trois étages

+ *Langage.* LOAF vérifie la syntaxe, le vocabulaire (blocs et champs
  déclarés), les sortes des valeurs, les références entre manifestes, la
  cardinalité des champs et les gabarits. Ses refus portent un code `Lnnn`
  défini par la spécification de LOAF ; une erreur lexicale ou de syntaxe
  porte le code #code("E001").
+ *Ensemble de fichiers.* Les règles du vocabulaire et les contrôles de Hamac
  portent sur chaque manifeste et sur l'ensemble : contrats des capacités,
  secrets, volumes, empreintes, quantités. Commande :
  `hamac validate <fichiers ou répertoires…>`.
+ *Stack.* Quand l'ensemble contient une stack, Hamac vérifie aussi le choix
  des providers, compose le treillis des patrons et vérifie zones, routes et
  flux. `hamac validate` applique cet étage dès qu'une stack figure dans
  l'ensemble ; `hamac plan` l'applique toujours, avant de calculer la
  topologie.

Un ensemble que le langage refuse avant toute évaluation (syntaxe,
vocabulaire, sortes) n'est pas soumis aux étages suivants ; les autres
diagnostics d'un ensemble sont rapportés ensemble. Chaque diagnostic donne un
code, l'emplacement de l'instruction fautive (fichier, ligne, colonne) et un
message :

```
manifest.loaf:11:3: [E013] consumes db of web: exactly one of capability and service
```

Une erreur (`E…`, `L…`) fait échouer la commande ; un avertissement (`W…`) ne
la fait échouer qu'avec `--strict`.

== Refus du langage

Les fautes que LOAF refuse lui-même portent le code du langage, défini par sa
spécification. Les plus fréquentes dans des manifestes Hamac :

#tableau((auto, 1fr),
  [Code], [Exemple dans un manifeste Hamac],
  code("L001"), [bloc ou champ inconnu (`servcie`, `replica 3.`) ; champ
    calculé écrit à la main (`provider` dans une consommation) ; attribut
    absent d'un contrat (`{~.database.login}`)],
  code("L002"), [valeur hors de son énumération (`format docker.`) ;
    référence à un manifeste absent de l'ensemble (service d'une stack,
    bundle d'un profil)],
  code("L006"), [deux valeurs pour un champ qui n'en admet qu'une, par
    exemple écrites par deux fichiers],
  code("L007"), [champ obligatoire absent (`runtime`, `sha256` d'un
    artefact)],
  code("L008"), [fichier sans `loaf 0.1.`],
  code("L009"), [`use` d'un patron introuvable, ou versions incompatibles],
  code("L014"), [gabarit sans valeur : consommation d'une capacité sans
    provider dans l'ensemble],
)

== Catalogue <catalogue>

Les codes de Hamac sont les suivants ; l'étage est celui de @validation.
Chaque code est couvert par un cas de `tests/hamac/catalogue.t/cases/`, dont
le nom commence par le code. Le validateur #doit refuser chaque cas (avec
`--strict` pour les avertissements) en émettant ce code, et #doit accepter les
exemples d'`examples/` ; la suite de tests et la CI le vérifient.

#tableau((auto, auto, 1fr),
  [Code], [Étage], [Condition],
  code("E001"), [1], [erreur lexicale ou de syntaxe ; fichier illisible ;
    vocabulaire introuvable],
  code("E004"), [2], [nom de service qui n'est pas un nom DNS],
  code("E006"), [2], [champ qui en exige un autre : `min_replicas` sans
    `max_replicas` ou l'inverse ; `readiness_interval` ou `readiness_timeout`
    sans `readiness` ; route sans `zone` ; catégories d'un patron sans
    niveaux],
  code("E007"), [2], [valeur incorrecte : niveau d'assurance hors de son axe ;
    paramètre de bundle sans, ou avec à la fois, `value` et `items`, que le
    bundle ne déclare pas, ou donné sous une autre forme que celle de son
    type ;
    paramètres d'un bundle que `bundles` ne liste pas ; référence de secret
    sans backend],
  code("E008"), [2], [artefact autre qu'une image OCI déclaré pour
    plusieurs architectures],
  code("E009"), [2], [nœud d'une autre architecture que l'image d'OS de son
    profil],
  code("E011"), [2], [`sha256` d'un artefact ou d'une image d'OS qui n'est pas
    64 caractères hexadécimaux],
  code("E012"), [2], [bundle listé deux fois dans `bundles`, ou avant un
    bundle dont il dépend],
  code("E013"), [2], [consommation sans, ou avec à la fois, `capability` et
    `service`],
  code("E014"), [2], [réservation de ressource supérieure à sa limite],
  code("E016"), [2], [`replicas` inférieur à 1, ou `min_replicas` et
    `max_replicas` incohérents],
  code("E020"), [2], [référence non liée : `secret(x)` sans secret déclaré ;
    `host(t)` hors d'une consommation de `t` ; terme que Hamac ne sait pas
    rendre],
  code("E022"), [3], [la stack impose le provider d'une consommation que le
    service ne déclare pas],
  code("E023"), [3], [aucun provider pour une capacité, plusieurs sans choix
    de la stack, ou provider imposé qui ne fournit pas la capacité],
  code("E024"), [2], [provider d'une capacité sans le bloc de son contrat, ou
    bloc de contrat d'un service qui ne fournit pas la capacité],
  code("E031"), [2], [`mount` qui n'est pas un chemin absolu],
  code("E032"), [2], [`size` absent pour un volume persistant],
  code("E033"), [2], [volume `local` sans `rebuild`, dans un service sans
    `backup`],
  code("E034"), [2], [secret sans, ou avec à la fois, `ref` et `generate`],
  code("E035"), [2], [port d'une exposition absent des `port` du service],
  code("E040"), [3], [flux qui lit vers le haut],
  code("E041"), [3], [flux de mode `request` à travers une diode],
  code("E042"), [2–3], [zone ou niveau inconnu : niveau ou catégorie d'une
    zone hors du treillis de son patron, exigence d'assurance pour une zone
    que le patron ne définit pas (2) ; zone d'un service, classification
    d'une route ou niveau d'une zone absents du treillis composé (3)],
  code("E043"), [2], [route `public` qui exige aussi une classification, des
    catégories ou des rôles],
  code("E044"), [3], [route classée au-dessus de la zone de son service, ou
    catégorie absente de cette zone],
  code("E045"), [3], [route qui exige un rôle qu'aucun patron ne déclare],
  code("E046"), [3], [infrastructure imposée sans nœud de la zone d'un
    service et d'une de ses architectures],
  code("E050"), [3], [patrons aux niveaux incompatibles],
  code("E051"), [3], [zone définie deux fois avec des étiquettes ou des
    frontières différentes],
  code("E052"), [2], [contrainte ou objectif mal formé : sans ses
    deux-points, erreur de syntaxe, variable non sûre, prédicat qu'aucune
    règle ne définit],
  code("W001"), [2], [champ expérimental, sans stack qui écrit
    `accept_experimental`],
  code("W002"), [2], [stack sans service],
  code("W003"), [2], [manifeste défini dans plusieurs fichiers],
  code("W010"), [2], [image OCI non épinglée par empreinte],
  code("W011"), [2], [`timeout` d'un `health_check` qui n'est pas inférieur à
    son `interval`],
  code("W012"), [2], [valeur d'environnement qui ressemble à un secret
    littéral],
  code("W013"), [2], [profil de provisioning sans bundle ni
    `cloud_init_extra`],
)
