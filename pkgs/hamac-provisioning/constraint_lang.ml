(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** The constraint language of patterns ([kind: pattern]).

    First-order logic over the finite domains of a candidate topology
    (services, zones, hosts, flows, volumes), with linear arithmetic on
    integers and resource quantities. Quantifiers range over finite sets
    only, there is no recursion and no quantification over sets of sets:
    once instantiated on a real fleet the problem is decidable, and an
    unsatisfiable set of constraints can be explained by a minimal subset.

    This module parses and type-checks expressions. Instantiation and
    solving belong to the planner. Grammar and base functions:
    doc/typst/manifest-spec.typ, section « Contraintes ». *)

(* ============================================================ *)
(* Syntax                                                        *)
(* ============================================================ *)

type quantifier = Forall | Exists [@@deriving show]

type relop = Eq | Neq | Lt | Le | Gt | Ge | In | Subset [@@deriving show]

type expr =
  | Quant of quantifier * string * set * expr option * expr
  | Implies of expr * expr
  | Or of expr * expr
  | And of expr * expr
  | Not of expr
  | Cmp of relop * term * term
  | Term of term                          (** a boolean term: [stateful(s)] *)
[@@deriving show]

and term =
  | Int of int
  | Quantity of int * string              (** [4Gi], [500m] *)
  | Str of string
  | Var of string
  | App of string * term list
  | Field of string * string              (** [h.boot] *)
  | Add of term * term
  | Sub of term * term
  | Mul of term * int
  | Paren of expr
[@@deriving show]

and set =
  | Domain of string                      (** [services], [hosts]… *)
  | Set_of of string * term               (** [hosts_of(s)] *)
[@@deriving show]

(** A parse or type error, at a character offset of the source. *)
type error = { offset: int; message: string }

exception Fail of error

let fail offset fmt = Printf.ksprintf (fun message -> raise (Fail { offset; message })) fmt

(* ============================================================ *)
(* Lexer                                                         *)
(* ============================================================ *)

type token =
  | IDENT of string | INT of int | QTY of int * string | STRING of string
  | KW of string        (* forall exists in where and or not subset *)
  | SYM of string       (* : => = != < <= > >= ( ) , . + - * *)
  | EOF

let keywords = ["forall"; "exists"; "in"; "where"; "and"; "or"; "not"; "subset"]
let domains = ["services"; "zones"; "hosts"; "flows"; "volumes"]
let units = ["Ki"; "Mi"; "Gi"; "Ti"; "m"]

let is_ident_start c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
let is_ident_char c = is_ident_start c || (c >= '0' && c <= '9') || c = '-'
let is_digit c = c >= '0' && c <= '9'

(** Tokens with the offset where each starts. *)
let tokenize (s : string) : (token * int) list =
  let n = String.length s in
  let rec go i acc =
    if i >= n then List.rev ((EOF, n) :: acc)
    else
      let c = s.[i] in
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' then go (i + 1) acc
      else if is_digit c then begin
        let j = ref i in
        while !j < n && is_digit s.[!j] do incr j done;
        let v = int_of_string (String.sub s i (!j - i)) in
        let k = ref !j in
        while !k < n && is_ident_start s.[!k] do incr k done;
        let suffix = String.sub s !j (!k - !j) in
        if suffix = "" then go !j ((INT v, i) :: acc)
        else if List.mem suffix units then go !k ((QTY (v, suffix), i) :: acc)
        else fail !j "unknown unit '%s' (expected: %s)" suffix (String.concat ", " units)
      end
      else if is_ident_start c then begin
        let j = ref i in
        while !j < n && is_ident_char s.[!j] do incr j done;
        let w = String.sub s i (!j - i) in
        go !j (((if List.mem w keywords then KW w else IDENT w), i) :: acc)
      end
      else if c = '"' then begin
        match String.index_from_opt s (i + 1) '"' with
        | None -> fail i "unterminated string"
        | Some j -> go (j + 1) ((STRING (String.sub s (i + 1) (j - i - 1)), i) :: acc)
      end
      else
        let two = if i + 1 < n then String.sub s i 2 else "" in
        if List.mem two ["=>"; "!="; "<="; ">="] then go (i + 2) ((SYM two, i) :: acc)
        else if String.contains ":=<>(),.+-*" c then
          go (i + 1) ((SYM (String.make 1 c), i) :: acc)
        else fail i "unexpected character '%c'" c
  in
  go 0 []

(* ============================================================ *)
(* Parser (recursive descent, one token of lookahead)            *)
(* ============================================================ *)

type state = { mutable toks: (token * int) list }

let peek st = match st.toks with t :: _ -> t | [] -> (EOF, 0)
let advance st = match st.toks with _ :: r -> st.toks <- r | [] -> ()

let describe = function
  | IDENT s -> Printf.sprintf "'%s'" s
  | INT i -> string_of_int i
  | QTY (i, u) -> Printf.sprintf "%d%s" i u
  | STRING s -> Printf.sprintf "\"%s\"" s
  | KW k -> Printf.sprintf "'%s'" k
  | SYM s -> Printf.sprintf "'%s'" s
  | EOF -> "end of expression"

let expect st tok =
  let (t, off) = peek st in
  if t = tok then advance st
  else fail off "expected %s, found %s" (describe tok) (describe t)

let ident st =
  match peek st with
  | (IDENT s, _) -> advance st; s
  | (t, off) -> fail off "expected an identifier, found %s" (describe t)

let rec p_expr st : expr =
  match peek st with
  | (KW ("forall" | "exists" as q), _) ->
    advance st;
    let x = ident st in
    expect st (KW "in");
    let dom = p_set st in
    let guard = match peek st with
      | (KW "where", _) -> advance st; Some (p_expr st)
      | _ -> None
    in
    expect st (SYM ":");
    let body = p_expr st in
    Quant ((if q = "forall" then Forall else Exists), x, dom, guard, body)
  | _ -> p_impl st

(* The right-hand side of [=>] is a full expression, so that
   [a => forall x in …] is accepted. *)
and p_impl st =
  let l = p_disj st in
  match peek st with
  | (SYM "=>", _) -> advance st; Implies (l, p_expr st)
  | _ -> l

and p_disj st =
  let rec loop l = match peek st with
    | (KW "or", _) -> advance st; loop (Or (l, p_conj st))
    | _ -> l
  in loop (p_conj st)

and p_conj st =
  let rec loop l = match peek st with
    | (KW "and", _) -> advance st; loop (And (l, p_neg st))
    | _ -> l
  in loop (p_neg st)

and p_neg st = match peek st with
  | (KW "not", _) -> advance st; Not (p_neg st)
  | _ -> p_cmp st

and p_cmp st =
  let l = p_term st in
  let op = match peek st with
    | (SYM "=", _) -> Some Eq | (SYM "!=", _) -> Some Neq
    | (SYM "<", _) -> Some Lt | (SYM "<=", _) -> Some Le
    | (SYM ">", _) -> Some Gt | (SYM ">=", _) -> Some Ge
    | (KW "in", _) -> Some In | (KW "subset", _) -> Some Subset
    | _ -> None
  in
  match op with
  | None -> (match l with Paren e -> e | t -> Term t)
  | Some op -> advance st; Cmp (op, l, p_term st)

and p_term st =
  let rec loop l = match peek st with
    | (SYM "+", _) -> advance st; loop (Add (l, p_prod st))
    | (SYM "-", _) -> advance st; loop (Sub (l, p_prod st))
    | _ -> l
  in loop (p_prod st)

and p_prod st =
  let rec loop l = match peek st with
    | (SYM "*", _) ->
      advance st;
      (match peek st with
       | (INT k, _) -> advance st; loop (Mul (l, k))
       | (t, off) -> fail off "linear arithmetic only: '*' must be followed by an integer constant, found %s" (describe t))
    | _ -> l
  in loop (p_atom st)

and p_atom st = match peek st with
  | (INT i, _) -> advance st; Int i
  | (QTY (i, u), _) -> advance st; Quantity (i, u)
  | (STRING s, _) -> advance st; Str s
  | (SYM "(", _) -> advance st; let e = p_expr st in expect st (SYM ")"); Paren e
  | (IDENT f, _) ->
    advance st;
    (match peek st with
     | (SYM "(", _) ->
       advance st;
       let args = match peek st with
         | (SYM ")", _) -> []
         | _ ->
           let rec more acc = match peek st with
             | (SYM ",", _) -> advance st; more (p_term st :: acc)
             | _ -> List.rev acc
           in more [p_term st]
       in
       expect st (SYM ")");
       App (f, args)
     | (SYM ".", _) -> advance st; Field (f, ident st)
     | _ -> Var f)
  | (t, off) -> fail off "unexpected %s" (describe t)

and p_set st = match peek st with
  | (IDENT d, _) when List.mem d domains -> advance st; Domain d
  | (IDENT f, off) ->
    advance st;
    (match peek st with
     | (SYM "(", _) -> advance st; let a = p_term st in expect st (SYM ")"); Set_of (f, a)
     | _ -> fail off "unknown domain '%s' (expected: %s, or a set-valued function)"
              f (String.concat ", " domains))
  | (t, off) -> fail off "expected a domain, found %s" (describe t)

let parse_with entry (src : string) : ('a, error) result =
  try
    let st = { toks = tokenize src } in
    let e = entry st in
    match peek st with
    | (EOF, _) -> Ok e
    | (t, off) -> fail off "unexpected %s after a complete expression" (describe t)
  with Fail e -> Error e

let parse_expr = parse_with p_expr
let parse_term = parse_with p_term

(* ============================================================ *)
(* Type checking                                                 *)
(* ============================================================ *)

type sort =
  | Service | Zone | Host | Flow | Volume
  | Level | Category | Axis | Domain_name
  | Int_s | Quantity_s | Bool | String_s
  | Set of sort

let rec sort_name = function
  | Service -> "service" | Zone -> "zone" | Host -> "host" | Flow -> "flow"
  | Volume -> "volume" | Level -> "level" | Category -> "category"
  | Axis -> "assurance value" | Domain_name -> "failure domain"
  | Int_s -> "integer" | Quantity_s -> "quantity" | Bool -> "boolean"
  | String_s -> "string" | Set s -> "set of " ^ sort_name s

let domain_sort = function
  | "services" -> Service | "zones" -> Zone | "hosts" -> Host
  | "flows" -> Flow | _ -> Volume

(** Base functions: name, argument sorts, result sort. *)
let functions = [
  "zone", [Service], Zone;
  "level", [Zone], Level;
  "categories", [Zone], Set Category;
  "hosts_of", [Service], Set Host;
  "levels_on", [Host], Set Level;
  "failure_domains", [Set Host], Set Domain_name;
  "stateful", [Service], Bool;
  "src", [Flow], Service;
  "dst", [Flow], Service;
  "has", [Host; String_s], Bool;
]

(** Constants of a topology. *)
let constants = [ "hosts_used", Set Host; "moves", Int_s ]

let fields = [
  Host, "boot", Axis; Host, "operator", Axis; Host, "physical", Axis;
  Host, "memory", Quantity_s; Host, "cpu", Quantity_s;
]

(* A string literal stands for a name of an enumerated sort: a level, a
   category, an assurance value, a capability. *)
let compatible a b =
  a = b
  || (a = String_s && List.mem b [Level; Category; Axis; String_s])
  || (b = String_s && List.mem a [Level; Category; Axis; String_s])
  || (a = Int_s && b = Quantity_s) || (a = Quantity_s && b = Int_s)

let ordered = function
  | Int_s | Quantity_s | Level | Axis | String_s -> true
  | _ -> false

(* Offsets are not tracked through the AST: a type error is reported at the
   start of the expression, with a message naming the culprit. *)
let tfail fmt = fail 0 fmt

let rec type_term env (t : term) : sort =
  match t with
  | Int _ -> Int_s
  | Quantity _ -> Quantity_s
  | Str _ -> String_s
  | Var x ->
    (match List.assoc_opt x env with
     | Some s -> s
     | None ->
       match List.assoc_opt x constants with
       | Some s -> s
       | None ->
         if List.mem x domains then Set (domain_sort x)
         else tfail "unbound identifier '%s'" x)
  | Field (x, f) ->
    let s = type_term env (Var x) in
    (match List.find_opt (fun (s', f', _) -> s' = s && f' = f) fields with
     | Some (_, _, r) -> r
     | None -> tfail "%s '%s' has no field '%s'" (sort_name s) x f)
  | App ("count", [a]) ->
    (match type_term env a with
     | Set _ -> Int_s
     | s -> tfail "count expects a set, got a %s" (sort_name s))
  | App ("sum", [a; Var f]) ->
    (match type_term env a with
     | Set elt ->
       (match List.find_opt (fun (s', f', _) -> s' = elt && f' = f) fields with
        | Some (_, _, ((Int_s | Quantity_s) as r)) -> r
        | _ -> tfail "sum: '%s' is not a numeric field of a %s" f (sort_name elt))
     | s -> tfail "sum expects a set, got a %s" (sort_name s))
  | App (("count" | "sum") as f, args) ->
    tfail "%s: wrong number of arguments (%d)" f (List.length args)
  | App (f, args) ->
    (match List.find_opt (fun (n, _, _) -> n = f) functions with
     | None -> tfail "unknown function '%s'" f
     | Some (_, params, r) ->
       if List.length params <> List.length args then
         tfail "%s expects %d argument(s), got %d" f (List.length params) (List.length args);
       List.iter2 (fun p a ->
         let s = type_term env a in
         if not (compatible p s) then
           tfail "%s expects a %s, got a %s" f (sort_name p) (sort_name s))
         params args;
       r)
  | Add (a, b) | Sub (a, b) ->
    let sa = type_term env a and sb = type_term env b in
    if not (List.mem sa [Int_s; Quantity_s] && compatible sa sb) then
      tfail "arithmetic on a %s and a %s" (sort_name sa) (sort_name sb);
    if sa = Quantity_s || sb = Quantity_s then Quantity_s else Int_s
  | Mul (a, _) ->
    let s = type_term env a in
    if not (List.mem s [Int_s; Quantity_s]) then
      tfail "arithmetic on a %s" (sort_name s);
    s
  | Paren e -> type_expr env e; Bool

and type_set env = function
  | Domain d -> domain_sort d
  | Set_of (f, a) ->
    (match type_term env (App (f, [a])) with
     | Set elt -> elt
     | s -> tfail "%s is a %s, not a set" f (sort_name s))

and type_expr env (e : expr) : unit =
  match e with
  | Quant (_, x, dom, guard, body) ->
    let env = (x, type_set env dom) :: env in
    Option.iter (type_expr env) guard;
    type_expr env body
  | Implies (a, b) | Or (a, b) | And (a, b) -> type_expr env a; type_expr env b
  | Not a -> type_expr env a
  | Term t ->
    let s = type_term env t in
    if s <> Bool then tfail "a %s is not a condition" (sort_name s)
  | Cmp (op, a, b) ->
    let sa = type_term env a and sb = type_term env b in
    (match op with
     | Eq | Neq ->
       if not (compatible sa sb) then
         tfail "cannot compare a %s with a %s" (sort_name sa) (sort_name sb)
     | Lt | Le | Gt | Ge ->
       if not (compatible sa sb && ordered sa && ordered sb) then
         tfail "cannot order a %s and a %s" (sort_name sa) (sort_name sb)
     | In ->
       (match sb with
        | Set elt when compatible sa elt -> ()
        | _ -> tfail "'in' expects an element and a set, got a %s and a %s"
                 (sort_name sa) (sort_name sb))
     | Subset ->
       (match sa, sb with
        | Set x, Set y when compatible x y -> ()
        | _ -> tfail "'subset' expects two sets, got a %s and a %s"
                 (sort_name sa) (sort_name sb)))

(** Parse and type-check a constraint. *)
let check_constraint (src : string) : (expr, error) result =
  match parse_expr src with
  | Error e -> Error e
  | Ok e ->
    try type_expr [] e; Ok e with Fail err -> Error err

(** Parse and type-check an objective term: it must be numeric. *)
let check_objective (src : string) : (term, error) result =
  match parse_term src with
  | Error e -> Error e
  | Ok t ->
    try
      match type_term [] t with
      | Int_s | Quantity_s -> Ok t
      | s -> tfail "an objective must be numeric, got a %s" (sort_name s)
    with Fail err -> Error err
