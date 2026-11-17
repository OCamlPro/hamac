(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Voir {!Biscuit_gen}. *)

open Hamac_manifest.Types

exception Unknown_field of string
exception Unknown_level of string

(** Le rang d'un niveau : [blp::rank(L, I)] est déduit par le modèle
    hamac_blp de la position [I] du niveau dans la liste ordonnée [levels]
    du patron. *)
let levels (t : Loaf.t) : (string * int) list =
  List.filter_map (function
    | [Loaf.Fun (l, []); Loaf.Int i] -> Some (l, i)
    | _ -> None)
    (Loaf.find t "blp::rank")
  |> List.sort (fun (_, a) (_, b) -> compare a b)

let rank_of ~levels lvl =
  match List.assoc_opt lvl levels with
  | Some n -> n
  | None ->
    (match int_of_string_opt lvl with
     | Some n -> n
     | None -> raise (Unknown_level lvl))

let authorizer ~levels ~service (rl : route_label) : string =
  let b = Buffer.create 512 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  p "// Autoriseur Biscuit généré par hamac (provider hamac-biscuit)"
  ; p "// service: %s" service
  ; p "// route: %s" rl.route
  ; (if rl.methods <> [] then
       p "// méthodes: %s (le filtrage par méthode est appliqué par la bordure, au routage)"
         (String.concat ", " rl.methods))
  ; p "//"
  ; if rl.public then begin
      p "// route publique : aucun jeton exigé."
      ; p "allow if true;"
    end else begin
      (* Ordre fixe, lisible : classification, puis catégories, puis rôles. *)
      let ordered =
        let get field = List.filter (fun (f, _) -> f = field) rl.requirements in
        get "blp::classification" @ get "blp::category" @ get "rbac::role"
        @ List.filter (fun (f, _) ->
            not (List.mem f ["blp::classification"; "blp::category"; "rbac::role"]))
            rl.requirements in
      List.iter (fun (field, values) ->
        match field, values with
        | "blp::classification", [lvl] ->
          let n = rank_of ~levels lvl in
          p "// (1) pas de lecture vers le haut : le niveau du sujet domine %s (rang %d)" lvl n
          ; p "check if clearance_level($l), $l >= %d;" n
        | "blp::classification", _ ->
          raise (Unknown_field "blp::classification : exactement une valeur")
        | "blp::category", cats ->
          List.iter (fun c ->
            p "// (2) besoin d'en connaître : le sujet détient le compartiment %S" c
            ; p "check if compartment(%S);" c)
            cats
        | "rbac::role", roles ->
          p "// (3) clearance disjonctive (%s) : au moins un rôle, par jointure Datalog"
            (String.concat " ou " (List.map (fun r -> Printf.sprintf "%S" r) roles))
          ; List.iter (fun r -> p "valid_role(%S);" r) roles
          ; p "authorized_role($r) <- role($r), valid_role($r);"
          ; p "check if authorized_role($r);"
        | field, _ -> raise (Unknown_field field))
        ordered
      ; p "allow if true;"
    end
  ; Buffer.contents b

let authorizers_of_service ~levels (svc : service_manifest) : string =
  match svc.security with
  | None -> ""
  | Some sec ->
    String.concat "\n"
      (List.map (fun rl -> authorizer ~levels ~service:svc.name rl) sec.route_labels)

let token ~levels ~user ?level ?(categories = []) ?(roles = []) () : string =
  let b = Buffer.create 256 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  p "// Bloc autorité Biscuit — clearance du sujet (émis par le service d'auth)"
  ; p "user(%S);" user
  ; (match level with
     | Some lvl ->
       let n = rank_of ~levels lvl in
       p "clearance_level(%d); // %s" n lvl
     | None -> ())
  ; List.iter (fun c -> p "compartment(%S);" c) categories
  ; List.iter (fun r -> p "role(%S);" r) roles
  ; Buffer.contents b
