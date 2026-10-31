Le planificateur place chaque réplique sur un nœud de sa zone avec clingo
(programme hamac.lp sur la forme ASP des manifestes), le moins de nœuds
possible.

La capacité d'un nœud vaut pour chaque nœud, pas pour la zone : trois
répliques de 2100 Mi demandent 6300 Mi, soit deux nœuds de 4096 Mi en
volume, mais deux répliques ne tiennent pas ensemble sur un nœud. Il en faut
trois.

  $ hamac plan packing.loaf | sed -n '/^Zones/,/^Network/p'
  Zones:
    default: 1 service(s), 3 replica(s), 6300 MB RAM, 3000 mCPU
      - batch
  
  Proposed topology:
    3x node [default] amd64 — 4096Mi RAM, 4 CPU
  
  Network segments:

La répartition (spread host, ou failure_domain : un nœud proposé est son
propre domaine de panne) met les répliques d'un service sur des nœuds
distincts, alors que les trois tiendraient sur un seul. La simulation suit
le placement du plan.

  $ hamac plan spread.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    3x node [default] amd64 — 4096Mi RAM, 4 CPU
  
  $ hamac simulate spread.loaf 2>/dev/null | sed -n '/^Service placement/,/^$/p'
  Service placement:
    node-default-1 [zone: default]:
      - web
    node-default-2 [zone: default]:
      - web
    node-default-3 [zone: default]:
      - web
  

L'anti-affinité sépare deux services.

  $ hamac plan anti.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    2x node [default] amd64 — 4096Mi RAM, 4 CPU
  

Une réplique plus grande qu'un nœud n'a pas de place : le plan le dit.

  $ hamac plan oversized.loaf
  hamac: [ERROR] plan: service 'huge': a replica needs 8192 MiB and 500 mCPU, more than a node offers (4096 MiB, 4000 mCPU)
  [1]

La recherche est bornée (--time-limit, 30 s par défaut) : à l'échéance, le
plan garde le meilleur placement trouvé, avec un avertissement, et échoue
s'il n'en a trouvé aucun.

  $ hamac plan --time-limit 0 packing.loaf
  hamac: [ERROR] plan: no placement found within the time limit (0s)
  [1]

Selon le terminal, cmdliner cite ou non le nom de l'option : la sortie est
ramenée à une forme.

  $ hamac plan --time-limit=-1 packing.loaf > out 2>&1; echo "exit $?"
  exit 124
  $ sed "s/'--time-limit'/--time-limit/" out
  Usage: hamac plan [--help] [--debug] [--lib=DIR] [--time-limit=SECONDS]
         [OPTION]… [FILES]…
  hamac: option --time-limit: "-1" is not a non-negative number of seconds

Les exigences de placement se ramènent à des primitives que hamac.lp
respecte (separate, min_domains et leurs préférences) ; le module hamac_ha
en fournit les déclarations. Une primitive qu'aucun placement ne satisfait
est nommée, avec son témoin.

  $ hamac plan quorum.loaf 2>&1 | grep -v W001
  hamac: [ERROR] plan: no placement of the services satisfies min_domains(db,3) (db)

Une préférence passe avant la minimisation des nœuds : non satisfaite, elle
donne un avertissement par témoin.

  $ hamac plan soft.loaf 2>&1 | grep -v W001 | sed -n '/WARNING/p'
  hamac: [WARNING] preference not met: prefer_min_domains(db,2) (db)

Deux services critiques ne partagent pas une machine.

  $ hamac plan critical.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    2x node [default] amd64 — 4096Mi RAM, 4 CPU
  
  $ hamac simulate critical.loaf 2>/dev/null | sed -n '/^Service placement/,/^$/p'
  Service placement:
    node-default-1 [zone: default]:
      - auth
    node-default-2 [zone: default]:
      - billing
      - docs
  

Un nombre de domaines inférieur à 1 est refusé.

  $ hamac validate misuse.loaf 2>&1 | grep ERROR
  hamac: [ERROR] misuse.loaf:10:3: [E016] a service survives the loss of a failure domain only on at least 1 domain

Un plancher d'assurance d'une zone passe aux nœuds que le plan propose pour
elle : le plus haut des patrons, axe par axe.

  $ hamac plan floor.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    1x node [a] amd64 — 4096Mi RAM, 4 CPU, boot >= measured_tpm2, physical >= site
    1x node [b] amd64 — 4096Mi RAM, 4 CPU
  

Un nœud a une architecture, et une réplique ne va que sur un nœud d'une
architecture de son artefact. Le binaire arm64 demande un nœud arm64 ; les
deux répliques de 3 Gio de l'API remplissent deux nœuds amd64 ; l'image
multi-architecture (2 Gio) tient à côté du capteur, sur le nœud arm64.

  $ hamac plan arch.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    2x node [default] amd64 — 4096Mi RAM, 4 CPU
    1x node [default_arm64] arm64 — 4096Mi RAM, 4 CPU
  
  $ hamac simulate arch.loaf 2>/dev/null | sed -n '/^Service placement/,/^$/p'
  Service placement:
    node-default-1 [zone: default]:
      - api
    node-default-2 [zone: default]:
      - api
    node-default-arm64-1 [zone: default]:
      - cache
      - sensor
  
