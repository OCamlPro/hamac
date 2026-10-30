(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** A set of manifests taken together (doc/typst/manifest.typ, section
    « Validation »).

    The files form one LOAF set ({!Loaf_source.load}): the language resolves
    the references between manifests (a stack names its services and loads
    its patterns, modules, by use), the vocabulary resolves the providers,
    and the vocabulary and the security models that the patterns load check
    the zones, routes and flows of the services. *)

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

(** All findings of a set of files; W001 is dropped when a stack accepts
    experimental fields. *)
let run (ls : loaded list) : loaded list * finding list =
  let accept = List.exists (fun (_, (s : stack_manifest)) -> s.accept_experimental) (stacks_of ls) in
  let all = List.concat_map (fun l -> List.map (fun d -> (l.file, d)) l.diags) ls in
  let all = if accept then List.filter (fun (_, (d : Diagnostic.t)) -> d.code <> "W001") all
    else all in
  (ls, all)
