(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Provider Biscuit de Hamac : traduction des étiquettes de route d'un
    manifeste (bloc [security], champs ajoutés par les modèles de sécurité
    [blp] et [rbac] des patrons) en programmes Datalog Biscuit.

    - un {b autoriseur} par route : des [check] sur le niveau de clearance,
      les compartiments et les rôles du jeton ; la bordure (Sozu) l'applique
      avant de transmettre la requête au service ;
    - un {b bloc autorité} par sujet : la clearance du sujet, émis par le
      service d'auth et signé (clé privée de l'émetteur).

    Le mapping du treillis MLS vers Datalog exploite les trois dimensions :

    - classification Bell-LaPadula (pas de lecture vers le haut) : une
      comparaison d'entiers, [check if clearance_level($l), $l >= rang] ;
    - compartiments (besoin d'en connaître) : un [check] par catégorie,
      [check if compartment("rh")] ;
    - rôles (clearance disjonctive) : une règle de dérivation par rôle
      admis, [authorized_role($r) <- role($r), valid_role($r)], dont la
      jointure exprime le « ou » — et non une liste plate façon JWT. *)

open Hamac_manifest.Types

(** Le provider ne traduit que les champs de route qu'il connaît. *)
exception Unknown_field of string

(** Niveau inconnu des patrons (ni rang, ni rôle déclaré). *)
exception Unknown_level of string

(** Les niveaux Bell-LaPadula déclarés par les patrons de l'ensemble de
    fichiers, avec leur rang : la position dans la liste ordonnée [levels]
    du patron, du moins au plus sensible. *)
val levels : Loaf.t -> (string * int) list

(** L'autoriseur Biscuit (programme Datalog) de la route [rl] du service
    [service]. Une route [public] n'exige aucun jeton. *)
val authorizer : levels:(string * int) list -> service:string -> route_label -> string

(** Les autoriseurs de toutes les routes d'un service, séparés par une
    ligne de commentaire, dans l'ordre des routes du manifeste. *)
val authorizers_of_service : levels:(string * int) list -> service_manifest -> string

(** Le bloc autorité Biscuit d'un jeton : la clearance du sujet [user].
    [level] est un niveau déclaré par les patrons (traduit en rang) ou un
    rang littéral ; [categories] et [roles] sont les compartiments et rôles
    du sujet. *)
val token : levels:(string * int) list -> user:string -> ?level:string ->
  ?categories:string list -> ?roles:string list -> unit -> string
