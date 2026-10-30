(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(* La représentation des types [error], [symbol] et des modèles est lue et
   construite par clingo_stubs.c : l'ordre des constructeurs et des champs
   y est figé. *)

type error_code = Runtime | Logic | Bad_alloc | Unknown

type error = { code : error_code; message : string }

exception Error of error

let () = Callback.register_exception "Hamac_clingo.Clingo.Error" (Error { code = Unknown; message = "" })

let string_of_code = function
  | Runtime -> "runtime"
  | Logic -> "logic"
  | Bad_alloc -> "bad_alloc"
  | Unknown -> "unknown"

let pp_error ppf e = Fmt.pf ppf "clingo (%s): %s" (string_of_code e.code) e.message

let () =
  Printexc.register_printer (function
    | Error e -> Some (Fmt.str "Clingo.Error: %a" pp_error e)
    | _ -> None)

type symbol =
  | Inf
  | Sup
  | Int of int
  | Str of string
  | Fun of string * symbol list
  | Neg of string * symbol list

(* Les chaînes de clingo s'échappent comme en C : barre oblique inverse,
   guillemet et fin de ligne. *)
let escape s =
  let b = Buffer.create (String.length s) in
  String.iter (function
    | '\\' -> Buffer.add_string b "\\\\"
    | '"' -> Buffer.add_string b "\\\""
    | '\n' -> Buffer.add_string b "\\n"
    | c -> Buffer.add_char b c) s;
  Buffer.contents b

let rec pp_symbol ppf = function
  | Inf -> Fmt.string ppf "#inf"
  | Sup -> Fmt.string ppf "#sup"
  | Int n -> Fmt.int ppf n
  | Str s -> Fmt.pf ppf "\"%s\"" (escape s)
  | Fun (f, args) -> pp_fun ppf "" f args
  | Neg (f, args) -> pp_fun ppf "-" f args

and pp_fun ppf sign f args =
  match args with
  | [] when f = "" -> Fmt.pf ppf "%s()" sign
  | [] -> Fmt.pf ppf "%s%s" sign f
  | [ x ] when f = "" -> Fmt.pf ppf "%s(%a,)" sign pp_symbol x
  | _ -> Fmt.pf ppf "%s%s(%a)" sign f Fmt.(list ~sep:(any ",") pp_symbol) args

let rank = function Inf -> 0 | Int _ -> 1 | Fun _ | Neg _ -> 2 | Str _ -> 3 | Sup -> 4

let rec compare_symbol a b =
  match a, b with
  | Int x, Int y -> Int.compare x y
  | Str x, Str y -> String.compare x y
  | (Fun (f, xs) | Neg (f, xs)), (Fun (g, ys) | Neg (g, ys)) ->
    let c = Int.compare (List.length xs) (List.length ys) in
    if c <> 0 then c
    else
      let c = String.compare f g in
      if c <> 0 then c
      else
        let sign = function Neg _ -> 1 | _ -> 0 in
        let c = Int.compare (sign a) (sign b) in
        if c <> 0 then c else List.compare compare_symbol xs ys
  | _ -> Int.compare (rank a) (rank b)

type t

external version : unit -> int * int * int = "clingo_ml_version"
external control_new : string array -> int -> t = "clingo_ml_control_new"
external free : t -> unit = "clingo_ml_control_free"
external control_add : t -> string -> string array -> string -> unit = "clingo_ml_control_add"
external control_ground : t -> (string * symbol list) array -> unit = "clingo_ml_control_ground"
external control_messages : t -> (int * string) list = "clingo_ml_control_messages"
external solve_start : t -> float -> unit = "clingo_ml_solve_start"

(* Ordre des constructeurs figé par clingo_ml_solve_next. *)
type next = Done | Timeout | Model of (symbol list * int array * int * bool)
[@@warning "-37"] (* construit par clingo_ml_solve_next *)

external solve_next : t -> int -> next = "clingo_ml_solve_next"

external solve_close : t -> int = "clingo_ml_solve_close"

let create ?(args = []) ?(message_limit = 20) () =
  control_new (Array.of_list args) message_limit

let with_control ?args ?message_limit f =
  let ctl = create ?args ?message_limit () in
  Fun.protect ~finally:(fun () -> free ctl) (fun () -> f ctl)

let add ctl ?(name = "base") ?(params = []) text =
  control_add ctl name (Array.of_list params) text

let ground ?(parts = [ ("base", []) ]) ctl = control_ground ctl (Array.of_list parts)

type warning =
  | Operation_undefined
  | Runtime_error
  | Atom_undefined
  | File_included
  | Variable_unbounded
  | Global_variable
  | Other

let warning_of_code = function
  | 0 -> Operation_undefined
  | 1 -> Runtime_error
  | 2 -> Atom_undefined
  | 3 -> File_included
  | 4 -> Variable_unbounded
  | 5 -> Global_variable
  | _ -> Other

(* La primitive rend les messages du plus récent au plus ancien. *)
let messages ctl =
  List.rev_map (fun (c, m) -> (warning_of_code c, m)) (control_messages ctl)

type show = Shown | Atoms | Terms | All

(* clingo_show_type_e *)
let show_bits = function Shown -> 2 | Atoms -> 4 | Terms -> 8 | All -> 31

type model = {
  symbols : symbol list;
  cost : int list;
  number : int;
  optimality_proven : bool;
}

type outcome = { satisfiable : bool option; exhausted : bool; interrupted : bool }

(* clingo_solve_result_e *)
let outcome_of_bits r =
  let has b = r land b <> 0 in
  { satisfiable = (if has 1 then Some true else if has 2 then Some false else None);
    exhausted = has 4;
    interrupted = has 8 }

let fold ?(show = Shown) ?time_limit ctl ~init f =
  let bits = show_bits show in
  let limit = match time_limit with
    | Some l when l < 0. -> invalid_arg "Clingo.fold: negative time limit"
    | Some l -> l
    | None -> -1. in
  solve_start ctl limit;
  let rec loop acc =
    match solve_next ctl bits with
    | Done | Timeout -> acc
    | Model (symbols, cost, number, optimality_proven) ->
      let m = { symbols = List.sort_uniq compare_symbol symbols;
                cost = Array.to_list cost; number; optimality_proven } in
      loop (f acc m)
  in
  match loop init with
  | acc -> (acc, outcome_of_bits (solve_close ctl))
  | exception e ->
    let bt = Printexc.get_raw_backtrace () in
    (* L'erreur d'origine prime sur celle, éventuelle, de la fermeture. *)
    (try ignore (solve_close ctl) with Error _ -> ());
    Printexc.raise_with_backtrace e bt

let best ?show ?time_limit ctl =
  match fold ?show ?time_limit ctl ~init:None (fun _ m -> Some m) with
  | Some m, outcome -> Some (m, outcome)
  | None, _ -> None

let optimal ?show ?time_limit ctl =
  match best ?show ?time_limit ctl with
  | Some ({ cost = _ :: _; _ }, outcome) when not outcome.exhausted ->
    raise (Error { code = Runtime;
                   message = "the search stopped before the optimum was proven \
                              (time limit, interruption, or --models)" })
  | Some (m, _) -> Some m
  | None -> None
