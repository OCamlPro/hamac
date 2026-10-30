(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Liaison OCaml de libclingo, le solveur ASP de Potassco (API C,
    [clingo.h], clingo 5.5 ou plus récent de la série 5).

    L'usage type : créer un contrôle, lui ajouter des programmes, ground
    la partie [base], puis parcourir les modèles :

    {[
      Clingo.with_control ~args:[ "--opt-mode=opt" ] (fun ctl ->
          Clingo.add ctl "1 { p(1..3) } 1. #minimize { X : p(X) }.";
          Clingo.ground ctl;
          match Clingo.optimal ctl with
          | Some m -> m.symbols, m.cost   (* [Fun ("p", [Int 1])], [1] *)
          | None -> assert false)
    ]}

    Les ressources de clingo sont libérées par {!free} (ou {!with_control}),
    à défaut par le GC. Toute erreur de clingo lève {!Error}. Un contrôle
    n'est pas partagé entre threads ; le verrou du runtime OCaml est relâché
    pendant le grounding et la recherche. *)

(** {1 Erreurs} *)

type error_code =
  | Runtime    (** entrée invalide : programme mal formé, option inconnue… *)
  | Logic      (** mauvais usage de l'API (contrôle libéré, résolution en cours…) *)
  | Bad_alloc  (** mémoire épuisée *)
  | Unknown    (** autre *)

type error = { code : error_code; message : string }

exception Error of error
(** Une erreur de clingo. Le message est celui de clingo, suivi des erreurs
    que son journal a reçues pendant l'appel (une erreur d'analyse, par
    exemple, n'y est détaillée que là). *)

val pp_error : error Fmt.t

(** {1 Symboles} *)

(** Un terme clos de clingo. Une constante [c] est [Fun ("c", [])], un tuple
    une fonction de nom vide, [-f(x)] (négation classique) [Neg ("f", [x])].
    Les constructeurs suivent ceux de [Loaf.value]. *)
type symbol =
  | Inf                             (** [#inf] *)
  | Sup                             (** [#sup] *)
  | Int of int                      (** entier (32 bits côté clingo) *)
  | Str of string                   (** chaîne *)
  | Fun of string * symbol list     (** fonction, constante ou tuple *)
  | Neg of string * symbol list     (** fonction niée *)

val pp_symbol : symbol Fmt.t
(** La syntaxe de clingo : [f(1,"a")], [(1,2)], [-p], [#inf]. *)

val compare_symbol : symbol -> symbol -> int
(** Un ordre total et déterministe : [#inf] < entiers < fonctions <
    chaînes < [#sup] ; les fonctions par arité, nom, signe (positive
    d'abord) puis arguments. Il ne dépend pas de la représentation interne
    de clingo, et donne aux symboles d'un modèle un ordre stable. *)

(** {1 Contrôle} *)

type t
(** Un contrôle clingo : programmes, grounding, résolution. *)

val version : unit -> int * int * int
(** La version de libclingo liée (majeure, mineure, révision). *)

val create : ?args:string list -> ?message_limit:int -> unit -> t
(** Un contrôle, configuré par les options de la ligne de commande de
    clingo ([args], par exemple [["--opt-mode=optN"; "--models=0"]]).
    [message_limit] (20 par défaut) : nombre de messages du journal au-delà
    duquel clingo abandonne. *)

val free : t -> unit
(** Libère le contrôle (idempotent). Tout usage ultérieur lève
    [Error { code = Logic; _ }]. *)

val with_control : ?args:string list -> ?message_limit:int -> (t -> 'a) -> 'a
(** [with_control f] crée un contrôle, l'applique à [f] et le libère, que
    [f] rende ou lève. *)

val add : t -> ?name:string -> ?params:string list -> string -> unit
(** [add ctl text] ajoute le programme [text] à la partie [name] ([base]
    par défaut), de paramètres [params]. *)

val ground : ?parts:(string * symbol list) list -> t -> unit
(** Ground les parties données ([["base", []]] par défaut). *)

(** {1 Journal} *)

type warning =
  | Operation_undefined  (** opération arithmétique indéfinie *)
  | Runtime_error        (** erreur détaillée, suivie d'une exception *)
  | Atom_undefined       (** atome qui n'est la tête d'aucune règle *)
  | File_included        (** fichier inclus plusieurs fois *)
  | Variable_unbounded   (** variable CSP sans domaine *)
  | Global_variable      (** variable globale dans un agrégat *)
  | Other

val messages : t -> (warning * string) list
(** Les messages du journal de clingo reçus depuis la dernière lecture, dans
    l'ordre. Ils ne sont pas imprimés : à l'application de les montrer. *)

(** {1 Résolution} *)

(** Les symboles d'un modèle à lire. *)
type show =
  | Shown  (** ceux de [#show] (tous les atomes sans [#show]) *)
  | Atoms  (** tous les atomes *)
  | Terms  (** les termes de [#show t.] *)
  | All

type model = {
  symbols : symbol list;
  (** les symboles choisis par [show], dans l'ordre de {!compare_symbol} *)
  cost : int list;
  (** le coût, par priorité décroissante ; vide sans optimisation *)
  number : int;
  (** rang du modèle dans la résolution, à partir de 1 *)
  optimality_proven : bool;
  (** l'optimalité du modèle est prouvée (modes [optN]) *)
}

type outcome = {
  satisfiable : bool option;
  (** [Some true] : au moins un modèle ; [Some false] : aucun ; [None] :
      recherche interrompue avant de conclure *)
  exhausted : bool;
  (** l'espace de recherche a été parcouru : le dernier modèle d'une
      optimisation est optimal *)
  interrupted : bool;
}

val fold :
  ?show:show -> ?time_limit:float -> t -> init:'a -> ('a -> model -> 'a) -> 'a * outcome
(** [fold ctl ~init f] parcourt les modèles de la résolution, dans l'ordre
    où clingo les trouve (avec une optimisation, de coût décroissant), et
    rend l'accumulateur et le résultat de la résolution. La résolution est
    fermée même si [f] lève.

    [time_limit] : durée maximale de la recherche, en secondes (horloge
    murale). À l'échéance, la recherche est arrêtée : le résultat a
    [interrupted], et pas [exhausted]. Sans limite, la recherche va jusqu'à
    son terme. *)

val best : ?show:show -> ?time_limit:float -> t -> (model * outcome) option
(** Le dernier modèle trouvé et le résultat de la résolution : avec une
    optimisation, le meilleur modèle trouvé, optimal si [outcome.exhausted].
    [None] si aucun modèle n'a été trouvé (programme sans modèle, ou
    échéance atteinte avant le premier). *)

val optimal : ?show:show -> ?time_limit:float -> t -> model option
(** Le dernier modèle de la résolution : pour un programme avec
    optimisation, un modèle optimal ; sans optimisation, un modèle (le seul
    que clingo cherche par défaut). [None] si le programme n'a pas de
    modèle.
    @raise Error si le programme a une optimisation et que la recherche
    s'est arrêtée avant de prouver l'optimum (échéance, interruption, ou
    nombre de modèles limité par [--models]). *)
