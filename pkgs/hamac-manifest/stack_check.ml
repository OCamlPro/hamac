(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Validation of a set of manifests taken together: stages 2 (references)
    and 3 (semantics) of doc/typst/manifest-spec.typ, section « Validation ».

    Stage 1 is per file for YAML ({!Parser.diagnose_file}), per set of files
    for LOAF ({!Loaf_source.load}).
    Here the files form a stack — explicit, when a [kind: stack] is given,
    or implicit, for [hamac plan] on a list of services: its references are
    resolved, its patterns composed into a lattice, its zones, routes,
    providers, templates and flows checked against it. *)

open Types

type loaded = {
  file: string;
  manifest: manifest option;
    (** [None]: the file could not be parsed, or the entry only carries the
        diagnostics of a LOAF file *)
  diags: Diagnostic.t list;
}

(** A finding, attributed to a file. *)
type finding = string * Diagnostic.t

let is_loaf file = Filename.check_suffix file ".loaf"

(** A YAML manifest file. *)
let load file =
  let manifest, diags = Parser.diagnose_file (Fpath.v file) in
  { file; manifest; diags }

(** A set of LOAF files, loaded together ({!Loaf_source.load}): one entry per
    manifest, in the file of its block; the diagnostics of a file go with its
    first entry, or with an entry without manifest. *)
let load_loaf ?vocabulary (files : string list) : loaded list =
  let sources, diags = Loaf_source.load ?vocabulary files in
  let entries = List.map (fun (s : Loaf_source.source) ->
    { file = s.file; manifest = Some s.manifest; diags = [] }) sources in
  let of_file f = List.filter_map (fun (g, d) -> if g = f then Some d else None) diags in
  let files_with_diags = List.sort_uniq compare (List.map fst diags) in
  let entries, attached = List.fold_left (fun (acc, attached) e ->
    if List.mem e.file attached then (acc @ [e], attached)
    else (acc @ [{ e with diags = of_file e.file }], e.file :: attached))
    ([], []) entries in
  entries @ List.filter_map (fun f ->
    if List.mem f attached then None
    else Some { file = f; manifest = None; diags = of_file f }) files_with_diags

(** The files given to a command: each YAML file on its own, the LOAF files
    as one set. *)
let load_all ?vocabulary (files : string list) : loaded list =
  let loaf, yaml = List.partition is_loaf files in
  List.map load yaml @ (if loaf = [] then [] else load_loaf ?vocabulary loaf)

(** For commands that consume manifests: the manifests of the files and
    their warnings, or the errors that make them unusable (the analogue of
    {!Parser.load_file} for a set of files). *)
let load_files ?vocabulary (files : string list)
  : ((string * manifest) list * string list, string) result =
  let ls = load_all ?vocabulary files in
  let findings = List.concat_map (fun l -> List.map (fun d -> (l.file, d)) l.diags) ls in
  let errors, warnings = List.partition (fun (_, d) -> Diagnostic.is_error d) findings in
  let show = List.map (fun (f, d) -> Diagnostic.to_string_in f d) in
  if errors <> [] then Error (String.concat "\n" (show errors))
  else Ok (List.filter_map (fun l -> Option.map (fun m -> (l.file, m)) l.manifest) ls,
           show warnings)

let services_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MService s) -> Some (l.file, s) | _ -> None) ls

(** The providers of a set of LOAF files, by name. A LOAF set has to
    include the providers its services consume (the vocabulary resolves
    them): a service of the set that its stack does not name, or, without a
    stack, that declares a capability, is a provider, not a service to
    deploy. *)
let loaf_providers (ms : (string * manifest) list) : string list =
  let loaf = List.filter (fun (f, _) -> is_loaf f) ms in
  let stacks = List.filter_map (fun (_, m) -> match m with MStack s -> Some s | _ -> None) loaf in
  let named = List.concat_map (fun (s : stack_manifest) ->
    List.map (fun (r : stack_service_ref) -> r.ref_path) s.services) stacks in
  List.filter_map (fun (_, m) -> match m with
    | MService svc when (if stacks <> [] then not (List.mem svc.name named)
                         else svc.capability <> None) -> Some svc.name
    | _ -> None) loaf

(** The services to deploy: the services of [ls] but the LOAF providers. *)
let deployed_services_of (ls : loaded list) =
  let providers = loaf_providers
      (List.filter_map (fun l -> Option.map (fun m -> (l.file, m)) l.manifest) ls) in
  List.filter (fun (f, (s : service_manifest)) ->
    not (is_loaf f && List.mem s.name providers)) (services_of ls)

let patterns_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MPattern p) -> Some (l.file, p) | _ -> None) ls

let stacks_of (ls : loaded list) =
  List.filter_map (fun l -> match l.manifest with
    | Some (MStack s) -> Some (l.file, s) | _ -> None) ls

(* ============================================================ *)
(* Reference resolution                                          *)
(* ============================================================ *)

(** Directories searched for a pattern named in a stack, after the files
    given on the command line. *)
let pattern_dirs () =
  ["./patterns"] @
  (match Sys.getenv_opt "HOME" with
   | Some home -> [Filename.concat home ".hamac/patterns"]
   | None -> [])

let find_pattern_file name =
  List.find_map (fun dir ->
    if not (Sys.file_exists dir && Sys.is_directory dir) then None
    else
      Sys.readdir dir |> Array.to_list |> List.sort compare
      |> List.find_map (fun f ->
        if Filename.check_suffix f ".yml" || Filename.check_suffix f ".yaml" then
          let l = load (Filename.concat dir f) in
          match l.manifest with
          | Some (MPattern p) when p.pat_name = name -> Some l
          | _ -> None
        else None))
    (pattern_dirs ())

(** The files of a stack: the stack's service references, loaded relative
    to the stack file (E021 when missing), and the patterns it names,
    searched among the given files then in {!pattern_dirs} (E021), with
    their [extends] closure. A LOAF stack names its services and patterns,
    which the language requires among the given files: nothing is loaded
    for it. *)
let expand (given : loaded list) : loaded list * finding list =
  let findings = ref [] in
  let add f d = findings := (f, d) :: !findings in
  let known = ref given in
  let has_file file = List.exists (fun l -> l.file = file) !known in
  let yaml_stacks = List.filter (fun (f, _) -> not (is_loaf f)) in
  List.iter (fun (sfile, (stk : stack_manifest)) ->
    let dir = Filename.dirname sfile in
    List.iteri (fun i (r : stack_service_ref) ->
      let file = if Filename.is_relative r.ref_path then Filename.concat dir r.ref_path
        else r.ref_path in
      if not (Sys.file_exists file) then
        add sfile (Diagnostic.make "E021" ["services"; string_of_int i; "ref"]
                     (Printf.sprintf "'%s' not found (looked for %s)" r.ref_path file))
      else if not (has_file file) then known := !known @ [load file])
      stk.services)
    (yaml_stacks (stacks_of given));
  (* Patterns named by stacks, then the extends closure. *)
  let find_pattern name =
    List.exists (fun (_, (p : pattern_manifest)) -> p.pat_name = name) (patterns_of !known) in
  let rec require_pattern ~from ~path name =
    if name = "hamac-default" || find_pattern name then ()
    else match find_pattern_file name with
      | Some l ->
        known := !known @ [l];
        (match l.manifest with
         | Some (MPattern p) ->
           List.iteri (fun i e -> require_pattern ~from:l.file ~path:["extends"; string_of_int i] e)
             p.extends
         | _ -> ())
      | None ->
        add from (Diagnostic.make "E021" path
                    (Printf.sprintf "pattern '%s' not found (given files, %s)" name
                       (String.concat ", " (pattern_dirs ()))))
  in
  List.iter (fun (sfile, (stk : stack_manifest)) ->
    List.iteri (fun i n -> require_pattern ~from:sfile ~path:["patterns"; string_of_int i] n)
      stk.patterns) (stacks_of given);
  List.iter (fun (pfile, (p : pattern_manifest)) ->
    List.iteri (fun i n -> require_pattern ~from:pfile ~path:["extends"; string_of_int i] n)
      p.extends) (patterns_of !known);
  (!known, List.rev !findings)

(* ============================================================ *)
(* Checks                                                        *)
(* ============================================================ *)

(** Placeholders [{name}] of a template, without [{secret.…}] (stage 1) and
    the [{{ }}] escapes. *)
let placeholders (s : string) : string list =
  let n = String.length s in
  let rec go i acc =
    if i >= n then List.rev acc
    else if s.[i] = '{' && i + 1 < n && s.[i + 1] = '{' then go (i + 2) acc
    else if s.[i] = '{' then
      match String.index_from_opt s i '}' with
      | None -> List.rev acc
      | Some j ->
        let name = String.sub s (i + 1) (j - i - 1) in
        let acc = if String.length name >= 7 && String.sub name 0 7 = "secret." then acc
          else name :: acc in
        go (j + 1) acc
    else go (i + 1) acc
  in go 0 []

let check ~(providers : service_manifest list) (ls : loaded list) : Lattice.t * finding list =
  let findings = ref [] in
  let add file code path msg = findings := (file, Diagnostic.make code path msg) :: !findings in
  (* E010: one name per kind *)
  let kind_name = function
    | MService s -> ("service", s.name) | MPattern p -> ("pattern", p.pat_name)
    | MStack s -> ("stack", s.name) | MInfrastructure i -> ("infrastructure", i.name)
    | MProvisioningProfile p -> ("provisioning_profile", p.pp_name)
    | MBundle b -> ("bundle", b.bdl_name) in
  let seen = Hashtbl.create 16 in
  List.iter (fun l -> match l.manifest with
    | None -> ()
    | Some m ->
      let (k, n) = kind_name m in
      match Hashtbl.find_opt seen (k, n) with
      | Some other ->
        add l.file "E010" ["name"] (Printf.sprintf "%s '%s' is already defined in %s" k n other)
      | None -> Hashtbl.add seen (k, n) l.file) ls;
  (* Lattice *)
  let pats = patterns_of ls in
  let lattice, ldiags = Lattice.of_patterns (List.map snd pats) in
  List.iter (fun (pname, d) ->
    let file = match List.find_opt (fun (_, (p : pattern_manifest)) -> p.pat_name = pname) pats with
      | Some (f, _) -> f | None -> pname in
    findings := (file, d) :: !findings) ldiags;
  let services = services_of ls in
  let all_services = List.map snd services in
  (* Zones and route labels *)
  List.iter (fun (file, (svc : service_manifest)) ->
    match svc.security with
    | None -> ()
    | Some sec ->
      match Lattice.find lattice sec.zone with
      | None ->
        add file "E042" ["security"; "zone"]
          (Printf.sprintf "zone '%s' is not defined by the stack's patterns (zones: %s)"
             sec.zone (String.concat ", " (Lattice.zone_names lattice)))
      | Some z ->
        List.iteri (fun i (r : route_label) ->
          let p = ["security"; "route_labels"; string_of_int i] in
          (match r.classification with
           | None -> ()
           | Some c ->
             match Lattice.rank_of lattice.levels c with
             | None ->
               add file "E042" (p @ ["classification"])
                 (Printf.sprintf "level '%s' is not in the lattice (%s)" c
                    (String.concat " < " lattice.levels))
             | Some rank when rank > z.rank ->
               add file "E044" (p @ ["classification"])
                 (Printf.sprintf "route '%s' is classified %s, above zone %s (%s): a service \
                                  holds no data more sensitive than its zone"
                    r.route c z.name (Lattice.label_to_string z))
             | Some _ -> ());
          List.iter (fun cat ->
            if not (List.mem cat z.categories) then
              add file "E044" (p @ ["categories"])
                (Printf.sprintf "category '%s' of route '%s' is not a category of zone %s (%s)"
                   cat r.route z.name (Lattice.label_to_string z)))
            r.categories) sec.route_labels) services;
  (* Providers, overrides and templates *)
  let overrides =
    List.concat_map (fun (sfile, (stk : stack_manifest)) ->
      List.mapi (fun i (r : stack_service_ref) -> (sfile, i, r)) stk.services)
      (stacks_of ls) in
  let service_of_ref sfile (r : stack_service_ref) =
    if is_loaf sfile then
      (* A LOAF stack names the service. *)
      List.find_opt (fun (s : service_manifest) -> s.name = r.ref_path) all_services
    else
      let file = if Filename.is_relative r.ref_path
        then Filename.concat (Filename.dirname sfile) r.ref_path else r.ref_path in
      List.assoc_opt file services in
  (* For LOAF manifests, the vocabulary resolves the providers and checks
     the overrides (E022, E023), and the model fills the inject templates
     with the attributes of the provider: these checks are not repeated. *)
  List.iter (fun (sfile, i, (r : stack_service_ref)) ->
    match service_of_ref sfile r with
    | None -> ()
    | Some _ when is_loaf sfile -> ()
    | Some svc ->
      List.iteri (fun j (o : stack_consume_override) ->
        if not (List.exists (fun (c : consumption) -> c.name = o.consume_name) svc.consumes) then
          add sfile "E022" ["services"; string_of_int i; "consumes"; string_of_int j; "name"]
            (Printf.sprintf "service '%s' has no consumes entry named '%s'" svc.name o.consume_name))
        r.consumes_override) overrides;
  let candidates cap =
    List.filter (fun (p : service_manifest) -> p.capability = Some cap)
      (providers @ all_services)
    |> List.sort_uniq (fun (a : service_manifest) b -> compare a.name b.name) in
  let override_for (svc : service_manifest) name =
    List.find_map (fun (sfile, _, r) ->
      match service_of_ref sfile r with
      | Some s when s.name = svc.name ->
        List.find_map (fun (o : stack_consume_override) ->
          if o.consume_name = name then Some o.provider else None) r.consumes_override
      | _ -> None) overrides in
  List.iter (fun (file, (svc : service_manifest)) ->
    List.iteri (fun i (c : consumption) ->
      let p = ["consumes"; string_of_int i] in
      let check_keys keys =
        List.iter (fun (k, v) ->
          List.iter (fun ph ->
            if not (List.mem ph keys) then
              add file "E020" (p @ ["inject"; k])
                (Printf.sprintf "{%s} is not provided (available: %s)" ph
                   (String.concat ", " (List.map (fun x -> "{" ^ x ^ "}") keys))))
            (placeholders v)) c.inject in
      match c.capability, c.service with
      | Some cap, None ->
        let cands = candidates cap in
        let chosen = match override_for svc c.name with
          | Some pname ->
            (match List.find_opt (fun (x : service_manifest) -> x.name = pname) cands with
             | Some x -> Some x
             | None ->
               add file "E023" p
                 (Printf.sprintf "the stack forces provider '%s' for '%s', which provides no '%s'"
                    pname c.name cap);
               None)
          | None ->
            (match cands with
             | [x] -> Some x
             | [] ->
               add file "E023" p (Printf.sprintf "no provider of capability '%s'" cap); None
             | xs ->
               add file "E023" p
                 (Printf.sprintf "several providers of '%s' (%s): choose one in the stack" cap
                    (String.concat ", " (List.map (fun (x : service_manifest) -> x.name) xs)));
               None) in
        Option.iter (fun (prov : service_manifest) ->
          check_keys (List.map fst prov.provides)) chosen
      | None, Some target ->
        (match List.find_opt (fun (s : service_manifest) -> s.name = target) all_services with
         | Some t -> check_keys (["host"; "port"; "service_name"] @ List.map fst t.provides)
         | None -> ())   (* reported by the flows below, E020 *)
      | _ -> ())   (* E013, stage 1 *)
      svc.consumes) (List.filter (fun (file, _) -> not (is_loaf file)) services);
  (* Flows: E020, E040, E041 *)
  let _, ferrs = Flows.declared ~lattice all_services in
  List.iter (fun (e : Flows.error) ->
    match List.find_opt (fun (_, (s : service_manifest)) -> s.name = e.service) services with
    | Some (file, _) -> findings := (file, e.diag) :: !findings
    | None -> ()) ferrs;
  (lattice, List.rev !findings)

(** All findings of a set of files: per-file diagnostics, then stack-wide
    ones; W001 is dropped when a stack accepts experimental fields. *)
let run ~providers (given : loaded list) : loaded list * Lattice.t * finding list =
  let ls, ref_findings = expand given in
  let lattice, findings = check ~providers ls in
  let accept = List.exists (fun (_, (s : stack_manifest)) -> s.accept_experimental) (stacks_of ls) in
  let per_file = List.concat_map (fun l -> List.map (fun d -> (l.file, d)) l.diags) ls in
  let all = per_file @ ref_findings @ findings in
  let all = if accept then List.filter (fun (_, (d : Diagnostic.t)) -> d.code <> "W001") all
    else all in
  (ls, lattice, all)
