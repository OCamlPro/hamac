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
    3x node [default] — 4096Mi RAM, 4 CPU
  
  Network segments:

La répartition (spread host, ou failure_domain : un nœud proposé est son
propre domaine de panne) met les répliques d'un service sur des nœuds
distincts, alors que les trois tiendraient sur un seul. La simulation suit
le placement du plan.

  $ hamac plan spread.loaf 2>/dev/null | sed -n '/^Proposed/,/^$/p'
  Proposed topology:
    3x node [default] — 4096Mi RAM, 4 CPU
  
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
    2x node [default] — 4096Mi RAM, 4 CPU
  

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
  $ hamac plan --time-limit=-1 packing.loaf
  Usage: hamac plan [--help] [--debug] [--lib=DIR] [--time-limit=SECONDS]
         [OPTION]… [FILES]…
  hamac: option --time-limit: "-1" is not a non-negative number of seconds
  [124]
