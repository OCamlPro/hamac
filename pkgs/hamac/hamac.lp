% SPDX-License-Identifier: AGPL-3.0-only
% Copyright (C) 2026 OCamlPro <contact@ocamlpro.com>
%
% Le programme du planificateur de Hamac (ASP, clingo 5).
%
% Il s'ajoute à la forme ASP des manifestes (Loaf.asp : service/1,
% service_zone/2, service_memory_limit/3…) et place chaque réplique de
% chaque service à déployer sur un nœud de sa zone, en respectant la
% capacité des nœuds, la répartition demandée et les primitives de placement
% (separate, min_domains…), avec le moins de nœuds possible.
%
% Le planificateur (planner.ml) fixe la taille d'un nœud par -c node_memory=…
% -c node_cpu=… ; les valeurs ci-dessous ne servent qu'à lancer clingo à la
% main sur ce fichier et la forme ASP d'un ensemble de manifestes :
%
%   loaf export --asp -L <vocabulaire> <fichiers> > m.lp
%   clingo m.lp hamac.lp
%
% Le placement est un problème de bin packing (à deux dimensions) : prouver
% l'optimum peut être long. Le planificateur borne la recherche
% (--time-limit) et garde alors le meilleur placement trouvé.
%
% La forme ASP des manifestes et ce programme partagent un seul espace de
% noms : aucun prédicat d'ici ne doit être celui d'un bloc, d'un champ ou
% d'une énumération du vocabulaire (spread/1, par exemple, est l'énumération
% des répartitions ; d'où spread_out/1).
%
% Les primitives de placement sont des prédicats du vocabulaire, que ses
% champs et les modules (hamac_ha…) définissent ; ce programme les respecte,
% section « primitives ». violation(K, T) : la primitive K est violée, de
% témoin T ; unmet(K, T) : la préférence K n'est pas satisfaite.

#const node_memory = 4096.
#const node_cpu = 4000.
% relax = 1 : les primitives deviennent des pénalités, au plus haut niveau de
% priorité ; le planificateur s'en sert pour nommer celles qu'aucun
% placement ne satisfait.
#const relax = 0.

% ------------------------------------------------------------ services
% Les services à déployer : ceux que nomme la stack ; sans stack, ceux qui
% ne fournissent pas de capacité. Les autres sont des providers
% (cf. Stack_check.providers_of_set).
stacked :- stack(_).
deployed(S) :- service(S), stack_service(_, S).
deployed(S) :- service(S), not stacked, not service_capability(S, _).

zone_of(S, Z) :- deployed(S), service_zone(S, Z).
zone_of(S, default) :- deployed(S), not service_zone(S, _).

% Un service dimensionné automatiquement est planifié à son maximum.
replicas(S, N) :- deployed(S), service_max_replicas(S, N).
replicas(S, N) :- deployed(S), service_replicas(S, N), not service_max_replicas(S, _).
replicas(S, 1) :- deployed(S), not service_replicas(S, _), not service_max_replicas(S, _).

% La demande d'une réplique est sa limite (pas sa réservation) : le plan
% dimensionne pour le pire cas.
memory(S, (N + 1023) / 1024) :- deployed(S), service_memory_limit(S, N, ki).
memory(S, N)                 :- deployed(S), service_memory_limit(S, N, mi).
memory(S, N * 1024)          :- deployed(S), service_memory_limit(S, N, gi).
memory(S, N * 1048576)       :- deployed(S), service_memory_limit(S, N, ti).
memory(S, 256)               :- deployed(S), not service_memory_limit(S, _, _).

cpu(S, N * 1000) :- deployed(S), service_cpu_limit(S, N, core).
cpu(S, N)        :- deployed(S), service_cpu_limit(S, N, m).
cpu(S, 500)      :- deployed(S), not service_cpu_limit(S, _, _).

% Une réplique plus grande qu'un nœud ne peut être placée : le planificateur
% le signale au lieu de conclure à l'absence de plan.
oversized(S, M, C) :- memory(S, M), cpu(S, C), M > node_memory.
oversized(S, M, C) :- memory(S, M), cpu(S, C), C > node_cpu.

% Un service à état garde des données sur son nœud.
stateful(S) :- deployed(S), service_storage_class(S, _, C), C != ephemeral.

% ------------------------------------------------------------ architectures
% Les architectures où l'artefact d'un service s'exécute (amd64 sans arch),
% que le vocabulaire calcule (hamac::service_arch). Les répliques d'un
% service ont une même architecture, choisie parmi celles-là.
arch_of(S, A) :- deployed(S), hamac__service_arch(S, A).
zone_arch(Z, A) :- zone_of(S, Z), arch_of(S, A), not oversized(S, _, _).

% ------------------------------------------------------------ nœuds
% Un nœud candidat a une zone et une architecture : H = (Z, A, K). Autant
% de candidats par zone et par architecture que de répliques qui peuvent
% s'y exécuter : une réplique par nœud est toujours une solution, la
% minimisation retire les autres.
replica(S, 1..N) :- replicas(S, N).
zone_arch_replicas(Z, A, N) :- zone_arch(Z, A),
    N = #sum { R, S : zone_of(S, Z), arch_of(S, A), replicas(S, R) }.
host((Z, A, 1..N)) :- zone_arch_replicas(Z, A, N).
host_zone((Z, A, K), Z) :- host((Z, A, K)).
host_arch((Z, A, K), A) :- host((Z, A, K)).
% Un nœud proposé est son propre domaine de panne : la topologie ne déclare
% pas encore de domaines plus larges.
failure_domain(H, H) :- host(H).

% ------------------------------------------------------------ rangs
% Les nœuds proposés sont identiques, et les répliques d'un service aussi :
% sans briser ces symétries, le solveur parcourt des placements qui ne
% diffèrent que par les numéros des nœuds, et ne prouve plus l'optimum
% au-delà d'une vingtaine de répliques. Les règles qui suivent ne retirent
% aucun coût : tout placement se renumérote pour les satisfaire. (À revoir
% quand les nœuds seront ceux d'un inventaire, qui ne sont plus
% interchangeables.)
%
% Les nœuds d'une zone et d'une architecture sont numérotés à part, mais le
% rang reste celui de la zone : la réplique de rang R est sur l'un des
% nœuds 1..R de son architecture, ce que toute numérotation des nœuds dans
% l'ordre de leur réplique de plus petit rang satisfait.
%
% Rang d'une réplique dans sa zone : les plus grandes d'abord (mémoire puis
% processeur), puis par service et par numéro ; les répliques d'un service
% ont des rangs consécutifs.
key(S, I, Z, (-M, -C, S, I)) :- replica(S, I), zone_of(S, Z), memory(S, M), cpu(S, C),
                                not oversized(S, _, _).
rank(S, I, N + 1) :- key(S, I, Z, X), N = #count { Y : key(_, _, Z, Y), Y < X }.

% ------------------------------------------------------------ placement
% Les nœuds sont numérotés dans l'ordre de leur réplique de plus petit
% rang : la réplique de rang R est sur l'un des nœuds 1..R.
1 { place(S, I, (Z, A, K)) : host((Z, A, K)), arch_of(S, A), K <= R } 1 :-
    rank(S, I, R), zone_of(S, Z).
on(S, H) :- place(S, _, H).
runs_on(S, A) :- place(S, _, (_, A, _)).
:- deployed(S), 2 { runs_on(S, A) : arch_of(S, A) }.
used(H) :- place(_, _, H).
zone_on(H, Z) :- on(S, H), zone_of(S, Z).

% Capacité d'un nœud.
:- host(H), #sum { M, S, I : place(S, I, H), memory(S, M) } > node_memory.
:- host(H), #sum { C, S, I : place(S, I, H), cpu(S, C) } > node_cpu.

% Répartition : les répliques d'un service réparti sont sur des nœuds
% distincts. Tant qu'un nœud est son propre domaine de panne,
% failure_domain ne demande pas plus que host.
spread_out(S) :- deployed(S), service_spread(S, host).
spread_out(S) :- deployed(S), service_spread(S, failure_domain).
:- spread_out(S), host(H), 2 { place(S, I, H) : replica(S, I) }.


% ------------------------------------------------------------ symétries
% Les nœuds utilisés d'une zone et d'une architecture sont les premiers.
:- host((Z, A, K)), K > 1, used((Z, A, K)), not used((Z, A, K - 1)).
% Les répliques d'un service, toutes de la même architecture, occupent des
% nœuds de numéro croissant : at_most(S, I, K), la réplique I de S est sur
% un nœud de numéro au plus K.
at_most(S, I, K) :- place(S, I, (_, _, K)).
at_most(S, I, K) :- at_most(S, I, K - 1), runs_on(S, A), zone_of(S, Z), host((Z, A, K)).
:- place(S, I + 1, (_, _, K)), replica(S, I), not at_most(S, I, K).

% Borne inférieure : en volume, une zone demande au moins
% ⌈mémoire / node_memory⌉ et ⌈processeur / node_cpu⌉ nœuds.
lower_bound(Z, (M + node_memory - 1) / node_memory) :- zone_of(_, Z),
    M = #sum { N * R, S : zone_of(S, Z), memory(S, N), replicas(S, R), not oversized(S, _, _) }.
lower_bound(Z, (C + node_cpu - 1) / node_cpu) :- zone_of(_, Z),
    C = #sum { N * R, S : zone_of(S, Z), cpu(S, N), replicas(S, R), not oversized(S, _, _) }.
% Et deux répliques qui demandent chacune plus de la moitié d'un nœud (en
% mémoire ou en processeur) ne le partagent pas.
lower_bound(Z, N) :- zone_of(_, Z),
    N = #count { S, I : key(S, I, Z, _), memory(S, M), 2 * M > node_memory;
                 S, I : key(S, I, Z, _), cpu(S, C), 2 * C > node_cpu }.
:- lower_bound(Z, L), #count { H : used(H), host_zone(H, Z) } < L.
% Une zone d'une seule architecture utilise donc ses L premiers nœuds.
single_arch(Z, A) :- zone_arch(Z, A), #count { B : zone_arch(Z, B) } = 1.
:- lower_bound(Z, L), single_arch(Z, A), host((Z, A, K)), K <= L, not used((Z, A, K)).

% ------------------------------------------------------------ primitives
% separate(S, T) : S et T ne partagent jamais une machine (anti_affinity,
% ha::isolate_zones, ha::critical…).
violation(separate(S, T), H) :- separate(S, T), S != T, on(S, H), on(T, H).
unmet(prefer_separate(S, T), H) :- prefer_separate(S, T), S != T, on(S, H), on(T, H).

% min_domains(S, N) : les répliques de S sont sur au moins N domaines de
% panne (ha::stateful_domains…).
domains(S, M) :- deployed(S), M = #count { D : on(S, H), failure_domain(H, D) }.
violation(min_domains(S, N), S) :- min_domains(S, N), domains(S, M), M < N.
unmet(prefer_min_domains(S, N), S) :- prefer_min_domains(S, N), domains(S, M), M < N.

% Une primitive est respectée ; une préférence coûte 1 par manquement, avant
% le nombre de nœuds.
:- violation(_, _), relax = 0.
:~ violation(K, T), relax = 1. [1@2, K, T]
:~ unmet(K, T). [1@1, K, T]

% ------------------------------------------------------------ objectif
% Le moins de nœuds possible, à la priorité 0 : les préférences, à la
% priorité 1, passent avant.
#minimize { 1@0, H : used(H) }.

% ------------------------------------------------------------ sortie
#show place/3.
#show zone_of/2.
#show replicas/2.
#show memory/2.
#show cpu/2.
#show oversized/3.
#show violation/2.
#show unmet/2.
#show zone_leq/2.
#show enclave/1.
#show error/2.

% Prédicats des manifestes qu'un ensemble peut ne pas définir.
#defined stack/1.             #defined stack_service/2.
#defined service_capability/2.
#defined service_zone/2.      #defined service_replicas/2.
#defined service_max_replicas/2.
#defined service_memory_limit/3.  #defined service_cpu_limit/3.
#defined service_spread/2.    #defined service_anti_affinity/2.
#defined service_storage_class/3.
#defined hamac__service_arch/2.
#defined zone_leq/2.       #defined enclave/1.
#defined separate/2.     #defined prefer_separate/2.
#defined min_domains/2.  #defined prefer_min_domains/2.
#defined error/2.
