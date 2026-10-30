(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** [compare.exe OUT FILE…] : les manifestes YAML des fichiers [.yml] et
    [.yaml], lus chacun seul, et ceux des fichiers [.loaf], lus ensemble,
    appariés par sorte et par nom (le nom YAML avec [_] lu [-], comme le
    sujet LOAF). Pour chaque paire, la valeur [Types] de chaque côté est
    écrite dans [OUT/<sorte>-<nom>.yaml] et [OUT/<sorte>-<nom>.loaf], et la
    paire est listée sur la sortie ; un manifeste sans pendant est signalé.

    Avant l'écriture, les listes qui sont des ensembles en LOAF (champs à
    plusieurs valeurs, sous-blocs) sont triées des deux côtés : LOAF les
    donne dans l'ordre des termes, YAML dans l'ordre d'écriture, et cet
    écart-là n'est pas une différence de contenu. Les listes positionnelles
    (niveaux d'un treillis, commande de readiness, pre/post d'une sauvegarde,
    éléments d'un paramètre, bundles d'un profil) gardent leur ordre. *)

open Hamac_manifest
open Types

let sort l = List.sort compare l

let service (s : service_manifest) =
  { s with
    inputs = sort s.inputs;
    consumes = sort (List.map (fun (c : consumption) -> { c with inject = sort c.inject }) s.consumes);
    provides = sort s.provides;
    security = Option.map (fun sec ->
        { sec with route_labels = sort (List.map (fun r ->
              { r with methods = sort r.methods; categories = sort r.categories;
                       required_clearance = sort r.required_clearance }) sec.route_labels) })
        s.security;
    ports = sort s.ports;
    environment = sort s.environment;
    metadata = { s.metadata with labels = sort s.metadata.labels;
                                 annotations = sort s.metadata.annotations };
    storage = sort s.storage;
    backup = Option.map (fun b -> { b with retention = sort b.retention }) s.backup;
    secrets = sort s.secrets;
    placement = Option.map (fun p ->
        { p with needs = sort p.needs; affinity = sort p.affinity;
                 anti_affinity = sort p.anti_affinity }) s.placement;
    exposure = sort s.exposure }

let pattern (p : pattern_manifest) =
  let by_id a b = compare a.cid b.cid in
  let by_term a b = compare (a.direction, a.term_src) (b.direction, b.term_src) in
  { p with
    extends = sort p.extends;
    lattice = Option.map (fun l -> { l with lat_categories = sort l.lat_categories }) p.lattice;
    zones = sort (List.map (fun z -> { z with zcategories = sort z.zcategories }) p.zones);
    pat_assurance = sort p.pat_assurance;
    constraints = List.sort by_id p.constraints;
    objectives = List.sort by_term p.objectives }

let stack (s : stack_manifest) =
  { s with
    patterns = sort s.patterns;
    services = sort (List.map (fun r -> { r with consumes_override = sort r.consumes_override })
                       s.services) }

let infrastructure (i : infrastructure_manifest) =
  { i with
    proposed_topology = Option.map (fun t ->
        { nodes = sort t.nodes; segments = sort t.segments; firewall = sort t.firewall })
        i.proposed_topology;
    warnings = sort i.warnings }

let profile (p : provisioning_profile_manifest) =
  { p with pp_bundles = List.map (fun b -> { b with bundle_params = sort b.bundle_params })
               p.pp_bundles }

let bundle (b : bundle_manifest) =
  { b with bdl_params = sort b.bdl_params; bdl_depends_on = sort b.bdl_depends_on }

let normalize = function
  | MService s -> MService (service s)
  | MPattern p -> MPattern (pattern p)
  | MStack s -> MStack (stack s)
  | MInfrastructure i -> MInfrastructure (infrastructure i)
  | MProvisioningProfile p -> MProvisioningProfile (profile p)
  | MBundle b -> MBundle (bundle b)

let key = function
  | MService s -> ("service", s.name)
  | MPattern p -> ("pattern", p.pat_name)
  | MStack s -> ("stack", s.name)
  | MInfrastructure i -> ("infrastructure", i.name)
  | MProvisioningProfile p -> ("provisioning_profile", p.pp_name)
  | MBundle b -> ("bundle", b.bdl_name)

let write file m =
  let oc = open_out file in
  let ppf = Format.formatter_of_out_channel oc in
  Format.pp_set_margin ppf 100;
  Format.fprintf ppf "%a@." pp_manifest (normalize m);
  close_out oc

let () =
  match Array.to_list Sys.argv with
  | _ :: out :: files ->
    let loaf, yaml = List.partition (fun f -> Filename.check_suffix f ".loaf") files in
    let of_yaml = List.filter_map (fun f ->
      match Parser.diagnose_file (Fpath.v f) with
      | Some m, _ -> Some m
      | None, ds -> List.iter (fun d -> prerr_endline (Diagnostic.to_string_in f d)) ds; None)
      yaml in
    let sources, diags = Loaf_source.load loaf in
    List.iter (fun (f, (d : Diagnostic.t)) ->
      if Diagnostic.is_error d then prerr_endline (Diagnostic.to_string_in f d)) diags;
    let of_loaf = List.map (fun (s : Loaf_source.source) -> s.manifest) sources in
    let dns = String.map (fun c -> if c = '_' then '-' else c) in
    let ykey m = let (k, n) = key m in (k, dns n) in
    (try Sys.mkdir out 0o755 with Sys_error _ -> ());
    let keys = List.sort_uniq compare (List.map ykey of_yaml @ List.map key of_loaf) in
    List.iter (fun (k, n) ->
      let y = List.find_opt (fun m -> ykey m = (k, n)) of_yaml in
      let l = List.find_opt (fun m -> key m = (k, n)) of_loaf in
      match y, l with
      | Some y, Some l ->
        let base = Filename.concat out (k ^ "-" ^ n) in
        write (base ^ ".yaml") y;
        write (base ^ ".loaf") l;
        print_endline (k ^ "-" ^ n)
      | Some _, None -> Printf.printf "%s %s: YAML only\n" k n
      | None, Some _ -> Printf.printf "%s %s: LOAF only\n" k n
      | None, None -> ()) keys
  | _ -> prerr_endline "usage: compare.exe OUT FILE…"; exit 2
