(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Validation of a set of manifests taken together: stage 3 (semantics) of
    doc/typst/manifest.typ, section « Validation ».

    The files form one LOAF set ({!Loaf_source.load}): the language resolves
    the references between manifests (a stack names its services and loads
    its patterns, modules, by use), and the vocabulary resolves the
    providers. The patterns of the set are composed into a lattice, against
    which the zones, routes and flows of the services are checked. *)

open Types

type loaded = {
  file: string;
  manifest: manifest option;
    (** [None]: the entry only carries the diagnostics of a file *)
  diags: Diagnostic.t list;
  locate: string list -> Diagnostic.loc option;
    (** location of a path of the manifest ({!Loaf_source.source}) *)
}

(** A finding, attributed to a file. *)
type finding = string * Diagnostic.t

(** A set of files, loaded together ({!Loaf_source.load}): one entry per
    manifest, in the file of its block; the diagnostics of a file go with its
    first entry, or with an entry without manifest. [lib]: directories of
    modules (patterns) besides the default ones. *)
let load_all ?vocabulary ?lib (files : string list) : loaded list =
  let sources, diags = Loaf_source.load ?vocabulary ?lib files in
  let entries = List.map (fun (s : Loaf_source.source) ->
    { file = s.file; manifest = Some s.manifest; diags = []; locate = s.locate }) sources in
  let of_file f = List.filter_map (fun (g, d) -> if g = f then Some d else None) diags in
  let files_with_diags = List.sort_uniq compare (List.map fst diags) in
  let entries, attached = List.fold_left (fun (acc, attached) e ->
    if List.mem e.file attached then (acc @ [e], attached)
    else (acc @ [{ e with diags = of_file e.file }], e.file :: attached))
    ([], []) entries in
  entries @ List.filter_map (fun f ->
    if List.mem f attached then None
    else Some { file = f; manifest = None; diags = of_file f; locate = (fun _ -> None) })
    files_with_diags

(** For commands that consume manifests: the manifests of the files and
    their warnings, or the errors that make them unusable. *)
let load_files ?vocabulary ?lib (files : string list)
  : ((string * manifest) list * string list, string) result =
  let ls = load_all ?vocabulary ?lib files in
  let findings = List.concat_map (fun l -> List.map (fun d -> (l.file, d)) l.diags) ls in
  let errors, warnings = List.partition (fun (_, d) -> Diagnostic.is_error d) findings in
  let show = List.map (fun (f, d) -> Diagnostic.to_string_in f d) in
  if errors <> [] then Error (String.concat "\n" (show errors))
  else Ok (List.filter_map (fun l -> Option.map (fun m -> (l.file, m)) l.manifest) ls,
           show warnings)

let services_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MService s) -> Some (l.file, s) | _ -> None) ls

(** [d] at the location of its path in the manifest of [l]. *)
let located (l : loaded) (d : Diagnostic.t) =
  match d.loc with
  | Some _ -> d
  | None -> { d with loc = l.locate d.path }

(** The providers of a set of files, by name. A set includes the providers
    its services consume (the vocabulary resolves them): a service that the
    stack of the set does not name, or, without a stack, that declares a
    capability, is a provider, not a service to deploy. *)
let providers_of_set (ms : (string * manifest) list) : string list =
  let stacks = List.filter_map (fun (_, m) -> match m with MStack s -> Some s | _ -> None) ms in
  let named = List.concat_map (fun (s : stack_manifest) ->
    List.map (fun (r : stack_service_ref) -> r.ref_service) s.services) stacks in
  List.filter_map (fun (_, m) -> match m with
    | MService svc when (if stacks <> [] then not (List.mem svc.name named)
                         else svc.capability <> None) -> Some svc.name
    | _ -> None) ms

(** The services to deploy: the services of [ls] but the providers. *)
let deployed_services_of (ls : loaded list) =
  let providers = providers_of_set
      (List.filter_map (fun l -> Option.map (fun m -> (l.file, m)) l.manifest) ls) in
  List.filter (fun (_, (s : service_manifest)) -> not (List.mem s.name providers))
    (services_of ls)

let patterns_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MPattern p) -> Some (l.file, p) | _ -> None) ls

let stacks_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MStack s) -> Some (l.file, s) | _ -> None) ls

(* ============================================================ *)
(* Checks                                                        *)
(* ============================================================ *)

let check (ls : loaded list) : Lattice.t * finding list =
  let findings = ref [] in
  let report (l : loaded) d = findings := (l.file, located l d) :: !findings in
  (* Lattice *)
  let pats = List.filter_map (fun l -> match l.manifest with
    | Some (MPattern p) -> Some (l, p) | _ -> None) ls in
  let lattice, ldiags = Lattice.of_patterns (List.map snd pats) in
  List.iter (fun (pname, d) ->
    match List.find_opt (fun (_, (p : pattern_manifest)) -> p.pat_name = pname) pats with
    | Some (l, _) -> report l d
    | None -> ()) ldiags;
  let services = List.filter_map (fun l -> match l.manifest with
    | Some (MService s) -> Some (l, s) | _ -> None) ls in
  let all_services = List.map snd services in
  let roles = List.concat_map (fun (_, (p : pattern_manifest)) -> p.pat_roles) pats in
  (* Zones and route labels *)
  List.iter (fun (l, (svc : service_manifest)) ->
    let add code path msg = report l (Diagnostic.make code path msg) in
    match svc.security with
    | None -> ()
    | Some sec ->
      match Lattice.find lattice sec.zone with
      | None ->
        add "E042" ["security"; "zone"]
          (Printf.sprintf "zone '%s' of %s is not defined by the stack's patterns (zones: %s)"
             sec.zone svc.name (String.concat ", " (Lattice.zone_names lattice)))
      | Some z ->
        List.iteri (fun i (r : route_label) ->
          let p = ["security"; "route_labels"; string_of_int i] in
          (match r.classification with
           | None -> ()
           | Some c ->
             match Lattice.rank_of lattice.levels c with
             | None ->
               add "E042" (p @ ["classification"])
                 (Printf.sprintf "level '%s' of route '%s' is not in the lattice (%s)" c r.route
                    (String.concat " < " lattice.levels))
             | Some rank when rank > z.rank ->
               add "E044" (p @ ["classification"])
                 (Printf.sprintf "route '%s' is classified %s, above zone %s (%s): a service \
                                  holds no data more sensitive than its zone"
                    r.route c z.name (Lattice.label_to_string z))
             | Some _ -> ());
          List.iter (fun cat ->
            if not (List.mem cat z.categories) then
              add "E044" (p @ ["categories"])
                (Printf.sprintf "category '%s' of route '%s' is not a category of zone %s (%s)"
                   cat r.route z.name (Lattice.label_to_string z)))
            r.categories;
          List.iter (fun role ->
            if not (List.mem role roles) then
              add "E045" (p @ ["required_clearance"])
                (Printf.sprintf "route '%s' of %s requires the role %s, which no pattern declares%s"
                   r.route svc.name role
                   (match List.sort_uniq compare roles with
                    | [] -> ""
                    | rs -> " (roles: " ^ String.concat ", " rs ^ ")")))
            r.required_clearance) sec.route_labels) services;
  (* Flows: E040, E041 *)
  let _, ferrs = Flows.declared ~lattice all_services in
  List.iter (fun (e : Flows.error) ->
    match List.find_opt (fun (_, (s : service_manifest)) -> s.name = e.service) services with
    | Some (l, _) -> report l e.diag
    | None -> ()) ferrs;
  (lattice, List.rev !findings)

(** All findings of a set of files: per-file diagnostics, then stack-wide
    ones; W001 is dropped when a stack accepts experimental fields. *)
let run (ls : loaded list) : loaded list * Lattice.t * finding list =
  let lattice, findings = check ls in
  let accept = List.exists (fun (_, (s : stack_manifest)) -> s.accept_experimental) (stacks_of ls) in
  let per_file = List.concat_map (fun l -> List.map (fun d -> (l.file, d)) l.diags) ls in
  (* A fault that the vocabulary and the composition of the lattice both
     see (a level of a zone outside the lattice of its pattern) is reported
     once. *)
  let seen (_, (d : Diagnostic.t)) =
    d.loc <> None
    && List.exists (fun (_, (e : Diagnostic.t)) -> e.code = d.code && e.loc = d.loc) per_file in
  let all = per_file @ List.filter (fun f -> not (seen f)) findings in
  let all = if accept then List.filter (fun (_, (d : Diagnostic.t)) -> d.code <> "W001") all
    else all in
  (ls, lattice, all)
