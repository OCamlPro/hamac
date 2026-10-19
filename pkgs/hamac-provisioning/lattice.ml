(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** The security lattice of a stack, and its zones.

    A label is a pair (level, set of categories), ordered by
    (n1, C1) ≤ (n2, C2) iff n1 ≤ n2 and C1 ⊆ C2: Bell-LaPadula with
    compartments. A zone has a name, a label and a boundary. The lattice and
    the zones come from the stack's patterns; without any, the built-in
    pattern [hamac-default] applies: levels and zones public < default <
    internal < secure, no category — the semantics of format 1.0. *)

open Manifest_types

type zone = {
  name: string;
  level: string;
  rank: int;                 (** index of [level] in [levels] *)
  categories: string list;   (** sorted *)
  boundary: string;          (** firewall | diode *)
}

type t = {
  levels: string list;       (** from the least to the most sensitive *)
  categories: string list;
  zones: zone list;
}

let rank_of levels level =
  let rec go i = function
    | [] -> None
    | l :: _ when l = level -> Some i
    | _ :: rest -> go (i + 1) rest
  in go 0 levels

let builtin_levels = ["public"; "default"; "internal"; "secure"]

let default = {
  levels = builtin_levels;
  categories = [];
  zones = List.mapi (fun i l ->
      { name = l; level = l; rank = i; categories = []; boundary = "firewall" })
      builtin_levels;
}

let find t name = List.find_opt (fun z -> z.name = name) t.zones

let subset a b = List.for_all (fun x -> List.mem x b) a

(** [leq t a b]: zone [a]'s label is below or equal to zone [b]'s. *)
let leq a b = a.rank <= b.rank && subset a.categories b.categories

let zone_names t = List.map (fun z -> z.name) t.zones

(** The lattice of a set of patterns: lattices must be equal or extend one
    another (same levels in the same order, categories growing), E050; a
    zone defined twice must have the same label, E051. Diagnostics are
    attributed to the pattern they come from. *)
let of_patterns (patterns : pattern_manifest list) : t * (string * Diagnostic.t) list =
  let diags = ref [] in
  let err pat code path msg = diags := (pat, Diagnostic.make code path msg) :: !diags in
  let levels, categories =
    List.fold_left (fun (levels, cats) (p : pattern_manifest) ->
      match p.lattice, levels with
      | None, _ -> (levels, cats)
      | Some l, None -> (Some l.levels, l.lat_categories)
      | Some l, Some lv ->
        if l.levels <> lv then begin
          err p.pat_name "E050" ["lattice"; "levels"]
            (Printf.sprintf "levels %s differ from %s declared by another pattern of the stack"
               (String.concat " < " l.levels) (String.concat " < " lv));
          (levels, cats)
        end else
          (levels, List.sort_uniq compare (cats @ l.lat_categories)))
      (None, []) patterns
  in
  let levels = Option.value levels ~default:builtin_levels in
  let defines_zones = List.exists (fun (p : pattern_manifest) -> p.zones <> []) patterns in
  let zones =
    if not defines_zones then
      List.mapi (fun i l -> { name = l; level = l; rank = i; categories = []; boundary = "firewall" })
        levels
    else
      List.fold_left (fun acc (p : pattern_manifest) ->
        List.fold_left (fun acc (i, (z : zone_decl)) ->
          let path = ["zones"; string_of_int i] in
          match rank_of levels z.zlevel with
          | None ->
            err p.pat_name "E042" (path @ ["level"])
              (Printf.sprintf "level '%s' is not in the lattice (%s)" z.zlevel
                 (String.concat " < " levels));
            acc
          | Some rank ->
            let zone = { name = z.zname; level = z.zlevel; rank;
                         categories = List.sort_uniq compare z.zcategories;
                         boundary = z.boundary } in
            match List.find_opt (fun y -> y.name = zone.name) acc with
            | Some y when y <> zone ->
              err p.pat_name "E051" path
                (Printf.sprintf "zone '%s' is already defined with another label or boundary"
                   z.zname);
              acc
            | Some _ -> acc
            | None -> acc @ [zone])
          acc (List.mapi (fun i z -> (i, z)) p.zones))
        [] patterns
  in
  ({ levels; categories; zones }, List.rev !diags)

let label_to_string (z : zone) =
  match z.categories with
  | [] -> z.level
  | cs -> Printf.sprintf "%s{%s}" z.level (String.concat "," cs)
