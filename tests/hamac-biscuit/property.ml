(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Test de propriété du mapping treillis MLS → Datalog Biscuit (lot L3 du
    grant Hyper Open X).

    Sur un treillis fini — les niveaux, catégories et rôles déclarés par le
    patron [exemple_rh] — tous les sujets possibles sont énumérés (niveau ×
    sous-ensemble de catégories × sous-ensemble de rôles). Pour chaque route
    d'un service, la décision de l'autoriseur généré par hamac-biscuit,
    évalué par un vrai moteur Datalog (clingo, via une traduction mécanique
    du programme émis), doit être exactement la décision du treillis :

    - pas de lecture vers le haut : rang(sujet) ≥ rang(classification) ;
    - besoin d'en connaître : catégories(route) ⊆ catégories(sujet) ;
    - clearance disjonctive : rôles(route) ∩ rôles(sujet) ≠ ∅ (ou vide).

    Usage : property.exe <racine du dépôt> *)

open Hamac_manifest

let is_alnum c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c = '_'

(** $x devient X : les variables du Datalog Biscuit en variables ASP. *)
let upper_vars s =
  let b = Buffer.create (String.length s) in
  let i = ref 0 in
  while !i < String.length s do
    if s.[!i] = '$' then begin
      incr i;
      let start = !i in
      while !i < String.length s && is_alnum s.[!i] do incr i done;
      Buffer.add_string b (String.uppercase_ascii (String.sub s start (!i - start)))
    end else begin
      Buffer.add_char b s.[!i];
      incr i
    end
  done;
  Buffer.contents b

(** Traduction mécanique, ligne par ligne, des formes émises par
    {!Biscuit_gen} vers l'ASP de clingo :

    - [allow if true;]         → [allow.] ;
    - [check if B;]            → [cK :- B.  :- not cK.] (le check échoue si
      [B] est faux) ;
    - [h <- b;]                → [h :- b.] ;
    - un fait [f(…);]          → [f(…).] ;
    - les commentaires [//] sont coupés. *)
let fresh = ref 0

let translate prog =
  String.split_on_char '\n' prog
  |> List.filter_map (fun line ->
    let line =
      match String.index_opt line '/' with
      | Some i when i + 1 < String.length line && line.[i + 1] = '/' ->
        String.sub line 0 i
      | _ -> line in
    let line = String.trim line in
    if line = "" then None
    else
      let body =
        if line.[String.length line - 1] = ';' then
          String.sub line 0 (String.length line - 1)
        else line
        |> String.trim in
      if body = "allow if true" then Some "allow."
      else if String.length body > 9 && String.sub body 0 9 = "check if " then begin
        incr fresh;
        let k = "c" ^ string_of_int !fresh in
        let b = upper_vars (String.sub body 9 (String.length body - 9)) in
        Some (Printf.sprintf "%s :- %s.\n:- not %s." k b k)
      end else (match String.index_opt body '<' with
        | Some i when i >= 1 && i + 3 <= String.length body
                      && String.sub body (i - 1) 4 = " <- " ->
          Some (upper_vars (String.sub body 0 (i - 1)) ^ " :- "
                ^ upper_vars (String.sub body (i + 3) (String.length body - i - 3)) ^ ".")
        | _ -> Some (upper_vars body ^ ".")))
  |> String.concat "\n"

(** La décision de l'autoriseur généré, évaluée par clingo : le programme
    (bloc autorité + autoriseur, traduits) est satisfiable ssi [allow] est
    vrai. *)
let biscuit_allows token_text auth_text =
  let asp = translate (token_text ^ "\n" ^ auth_text) ^ "\n:- not allow.\n" in
  (if Sys.getenv_opt "BISCUIT_DEBUG" <> None then Fmt.epr "--- ASP ---\n%s---\n%!" asp);
  Hamac_clingo.Clingo.with_control (fun ctl ->
    Hamac_clingo.Clingo.add ctl asp;
    Hamac_clingo.Clingo.ground ctl;
    Hamac_clingo.Clingo.best ctl <> None)

let subsets l =
  List.fold_left (fun acc x -> acc @ List.map (fun s -> x :: s) acc) [[]] l

let () =
  let root = if Array.length Sys.argv > 1 then Sys.argv.(1) else "." in
  let files = [Filename.concat root "examples/hr-stack"; Filename.concat root "providers"] in
  let ls = Stack_check.load_all files in
  let _, findings = Stack_check.run ls in
  let errors = List.filter (fun (_, d) -> Diagnostic.is_error d) findings in
  if errors <> [] then begin
    List.iter (fun (f, d) -> Fmt.epr "%s: %s@." f (Diagnostic.to_string_in f d)) errors;
    exit 1
  end;
  let model =
    match Loaf_source.model files with
    | Some t -> t
    | None -> Fmt.epr "cannot load the model@."; exit 1 in
  let levels = Hamac_biscuit.Biscuit_gen.levels model in
  let lvl_names = List.map fst levels in
  let categories =
    Loaf.find model "blp::pattern.category"
    |> List.filter_map (function [ _; Loaf.Fun (c, []) ] -> Some c | _ -> None) in
  let roles =
    Loaf.find model "rbac::pattern.role"
    |> List.filter_map (function [ _; Loaf.Fun (r, []) ] -> Some r | _ -> None) in
  let rank lvl = List.assoc lvl levels in
  (* Les services avec leurs routes étiquetées. *)
  let routes =
    List.filter_map (fun (l : Stack_check.loaded) ->
      match l.manifest with
      | Some (Types.MService s) ->
        (match s.security with
         | Some sec -> Some (List.map (fun rl -> (s.name, rl)) sec.route_labels)
         | None -> None)
      | _ -> None) ls
    |> List.concat in
  (* Sémantique du treillis, directement depuis l'étiquette de la route. *)
  let route_allows (rl : Types.route_label) (lvl, cats, roles) =
    if rl.public then true
    else
      let get f =
        List.find_opt (fun (x, _) -> x = f) rl.requirements
        |> Option.map snd |> Option.value ~default:[] in
      let classif_ok =
        match get "blp::classification" with
        | [c] -> rank lvl >= rank c
        | _ -> true in
      let cats_ok = List.for_all (fun c -> List.mem c cats) (get "blp::category") in
      let roles_ok =
        match get "rbac::role" with
        | [] -> true
        | rs -> List.exists (fun r -> List.mem r roles) rs in
      classif_ok && cats_ok && roles_ok in
  (* Tous les sujets du treillis fini. *)
  let subjects =
    List.concat_map (fun lvl ->
      List.concat_map (fun cats ->
        List.map (fun roles -> (lvl, cats, roles)) (subsets roles))
        (subsets categories))
      lvl_names in
  let n = ref 0 and bad = ref 0 in
  List.iter (fun (service, rl) ->
    let auth = Hamac_biscuit.Biscuit_gen.authorizer ~levels ~service rl in
    List.iter (fun (lvl, cats, roles) ->
      let token =
        Hamac_biscuit.Biscuit_gen.token ~levels ~user:"sujet"
          ~level:lvl ~categories:cats ~roles () in
      let got = biscuit_allows token auth in
      let want = route_allows rl (lvl, cats, roles) in
      incr n;
      if got <> want then begin
        incr bad;
        Fmt.epr "DIVERGENCE %s %s sujet(niveau=%s, cats=[%s], rôles=[%s]) : biscuit=%b treillis=%b@."
          service rl.route lvl (String.concat "," cats) (String.concat "," roles) got want
      end)
      subjects)
    routes;
  if !bad > 0 then begin
    Fmt.epr "%d décisions, %d divergences@." !n !bad;
    exit 1
  end;
  Printf.printf "%d sujets × %d routes = %d décisions : l'autoriseur Biscuit généré accepte exactement les accès permis par le treillis MLS.\n"
    (List.length subjects) (List.length routes) !n
