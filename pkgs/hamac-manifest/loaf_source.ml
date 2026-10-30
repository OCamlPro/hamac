(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Manifests, written in LOAF.

    A set of [.loaf] files is loaded as a whole: a manifest may name a block
    of another file (a stack its services, a profile its bundles), and the
    language checks these references against the whole set. The vocabulary
    of Hamac, [vocabulary/hamac.loaf] (module [hamac]), gives the blocks of
    the six kinds of manifests, their defaults (in comments) and the
    validations that only read the model. A pattern is a module, which a
    stack loads by [use] from the library directories ({!library_dirs}).

    Each subject of a block of the vocabulary becomes a {!Types.manifest}:

    - the name of a manifest, and every reference to one, is its subject
      with [_] replaced by [-] (convention of the vocabulary);
    - enumerated values are spelt with [-] ([oci_image] → [oci-image],
      [list_string] → [list[string]]), as the rest of Hamac expects;
    - a quantity [(512, mi)] becomes ["512Mi"], [(500, m)] ["500m"],
      [(90, d)] ["90d"];
    - terms rendered by Hamac and templates become the [{…}] strings that
      the resolver substitutes ({!render}).

    The model is read by {!Loaf.atoms}, with the locations of the facts,
    which the diagnostics need.

    Diagnostics: a refusal of the language ([Loaf.Diag.Error]) or an error
    of the model ({!Loaf.errors}) becomes a {!Diagnostic.t} located in its
    file; its code is the Hamac code that starts the message of a
    validation of the vocabulary ([[E013] …]), otherwise the code of the
    language ([L002]), or [E001] for a lexical or syntax error. The checks
    that the vocabulary does not express (digests, quantities, paths…),
    {!Checks.check}, are run on the manifests built here. *)

open Types

(* ============================================================ *)
(* Vocabulary                                                    *)
(* ============================================================ *)

let vocabulary_file = "hamac.loaf"

(** Directories of the modules that a manifest may [use], after the
    vocabulary: [./patterns] and [~/.hamac/patterns], when they exist. *)
let library_dirs () =
  ["./patterns"] @
  (match Sys.getenv_opt "HOME" with
   | Some home -> [Filename.concat home ".hamac/patterns"]
   | None -> [])
  |> List.filter (fun d -> Sys.file_exists d && Sys.is_directory d)

(** The directory of the vocabulary: [vocabulary] if given, otherwise the
    variable [HAMAC_VOCABULARY], otherwise the site where the package
    hamac-manifest installs it (dune-site: the install prefix once
    installed, [_build/install] during development). *)
let vocabulary_dir ?vocabulary () : (string, string) result =
  let has_vocabulary d = Sys.file_exists (Filename.concat d vocabulary_file) in
  match vocabulary with
  | Some d -> Ok d
  | None ->
    match Sys.getenv_opt "HAMAC_VOCABULARY" with
    | Some d when d <> "" -> Ok d
    | _ ->
      match List.find_opt has_vocabulary Sites.Sites.vocabulary with
      | Some d -> Ok d
      | None ->
        Error (Printf.sprintf
                 "the LOAF vocabulary of Hamac (%s) is not installed (looked in: %s); \
                  set HAMAC_VOCABULARY to its directory"
                 vocabulary_file
                 (match Sites.Sites.vocabulary with
                  | [] -> "no site location"
                  | ds -> String.concat ", " ds))

(* ============================================================ *)
(* The model, with the locations of its facts                    *)
(* ============================================================ *)

type value = Loaf.value

(** An atom of the model and the locations of the elements that denote it
    (none for an atom that is only deduced). *)
type fact = { args: value list; at: Diagnostic.loc list }

type model = (string, fact list) Hashtbl.t   (** predicate → facts, by arguments *)

let loc_of (l : Loaf.Loc.t) : Diagnostic.loc =
  { file = l.file; line = l.line; column = l.column }

let compare_args = List.compare Loaf.compare_value

(** The model of [t], indexed by predicate. *)
let model_of (t : Loaf.t) : model =
  let m : model = Hashtbl.create 256 in
  List.iter (fun (a : Loaf.atom) ->
    let prev = Option.value (Hashtbl.find_opt m a.pred) ~default:[] in
    Hashtbl.replace m a.pred ({ args = a.args; at = List.map loc_of a.at } :: prev))
    (Loaf.atoms t);
  Hashtbl.filter_map_inplace (fun _ facts ->
    Some (List.sort (fun a b -> compare_args a.args b.args) facts)) m;
  m

(** The facts of [pred] whose arguments start with [prefix]: the rest of
    their arguments, in the order of terms. *)
let rows (m : model) pred (prefix : value list) : (value list * fact) list =
  let rec strip p a = match p, a with
    | [], rest -> Some rest
    | x :: p, y :: a when Loaf.compare_value x y = 0 -> strip p a
    | _ -> None in
  Option.value (Hashtbl.find_opt m pred) ~default:[]
  |> List.filter_map (fun f -> Option.map (fun rest -> (rest, f)) (strip prefix f.args))

let first_loc (f : fact) = match f.at with l :: _ -> Some l | [] -> None

(* ============================================================ *)
(* Values                                                        *)
(* ============================================================ *)

(** A required field is absent: the language reports it (L007), and the
    manifest is not built. *)
exception Missing of string

let const = function Loaf.Fun (c, []) -> c | v -> Fmt.str "%a" Loaf.pp_value v

(** The name of a manifest, or of a reference to one. *)
let dns c = String.map (fun ch -> if ch = '_' then '-' else ch) c

let name v = dns (const v)

(** An enumerated value, spelt with [-] as the rest of Hamac expects. *)
let enum v = dns (const v)

let str = function Loaf.Str s -> s | v -> const v

let int = function Loaf.Int n -> n | v -> raise (Missing (Fmt.str "integer %a" Loaf.pp_value v))

let size_unit = function
  | "ki" -> "Ki" | "mi" -> "Mi" | "gi" -> "Gi" | "ti" -> "Ti" | u -> u

(** A quantity (integer, unit) as a string: [512Mi], [500m], [90d]. *)
let quantity n u =
  match const u with
  | "core" -> string_of_int (int n)
  | "m" -> string_of_int (int n) ^ "m"
  | u -> string_of_int (int n) ^ size_unit u

(** Context of the conversion of one set of files: the model and the
    diagnostics found while building the manifests. *)
type cx = {
  model: model;
  mutable diags: Diagnostic.t list;   (** newest first *)
}

let note cx ?loc code path message =
  cx.diags <- Diagnostic.make ?loc code path message :: cx.diags

(** A term rendered by Hamac, or a template, as a string of the [{…}]
    mini-language that the resolver substitutes:

    - [gen(alnum, 32)] → [{generate.alnum(32)}], [input(user)] →
      [{input.user}], [consumer(name)] → [{consumer.name}],
      [instance(name)] → [{service_name}], [secret(x)] → [{secret.x}];
    - [host(t)] → [{host}], where the host of [t] is the one that the
      resolver substitutes: in the [inject] of a consumption of [t] and in
      the contract of the capability of [t] ([host_of]);
    - [cat(…)] → the concatenation of its parts, an integer in decimal, a
      constant by its name.

    The template of an [inject] is already filled by the model with the
    attributes of the provider ([{~.user}] → [input(user)] of the provider):
    its [{input.…}] and [{service_name}] refer to the provider instance,
    which the resolver substitutes along with its [provides]. *)
let rec render cx ?loc ?host_of (v : value) : string =
  match v with
  | Loaf.Int n -> string_of_int n
  | Loaf.Str s -> s
  | Loaf.Fun (c, []) -> c
  | Loaf.Fun ("cat", parts) -> String.concat "" (List.map (render cx ?loc ?host_of) parts)
  | Loaf.Fun ("gen", [k; n]) -> Printf.sprintf "{generate.%s(%d)}" (const k) (int n)
  | Loaf.Fun ("input", [x]) -> Printf.sprintf "{input.%s}" (const x)
  | Loaf.Fun ("consumer", [x]) -> Printf.sprintf "{consumer.%s}" (const x)
  | Loaf.Fun ("instance", [Loaf.Fun ("name", [])]) -> "{service_name}"
  | Loaf.Fun ("secret", [x]) -> Printf.sprintf "{secret.%s}" (const x)
  | Loaf.Fun ("host", [t]) ->
    if host_of <> Some (const t) then
      note cx ?loc "E020" []
        (Printf.sprintf "host(%s) is only substituted in the inject of a consumption of %s \
                         and in the contract of its capability" (const t) (const t));
    "{host}"
  | v ->
    note cx ?loc "E020" []
      (Fmt.str "%a has no rendering in Hamac" Loaf.pp_value v);
    Fmt.str "%a" Loaf.pp_value v

(** A value of a bundle parameter: an integer, otherwise its rendering. *)
let param_of_text cx ?loc (v : value) : param_value =
  match v with
  | Loaf.Int n -> PInt n
  | Loaf.Str s -> PString s
  | v -> PString (render cx ?loc v)

(* ============================================================ *)
(* Field access                                                  *)
(* ============================================================ *)

(** Accessors to the fields of the block [kind] of subject [subj] (and of
    its sub-blocks, by the [path] of their subjects). *)
module F = struct
  let all cx kind path field = rows cx.model (kind ^ "." ^ field) path

  (** The values of a field, in the order of terms. *)
  let values cx kind path field =
    List.map (fun (rest, _) -> rest) (all cx kind path field)

  let opt cx kind path field =
    match values cx kind path field with v :: _ -> Some v | [] -> None

  let opt1 cx kind path field f =
    match opt cx kind path field with Some [v] -> Some (f v) | _ -> None

  let req1 cx kind path field f =
    match opt1 cx kind path field f with
    | Some v -> v
    | None -> raise (Missing (kind ^ "." ^ field))

  let list1 cx kind path field f =
    List.filter_map (function [v] -> Some (f v) | _ -> None) (values cx kind path field)

  let flag cx kind path field = values cx kind path field <> []

  (** A list field [f* [s]]: its values by increasing position. *)
  let indexed cx kind path field f =
    values cx kind path field
    |> List.filter_map (function [Loaf.Int i; v] -> Some (i, v) | _ -> None)
    |> List.sort (fun (i, _) (j, _) -> compare i j)
    |> List.map (fun (_, v) -> f v)

  (** A table field [f* k => v]. *)
  let table cx kind path field fk fv =
    List.filter_map (function [k; v] -> Some (fk k, fv v) | _ -> None)
      (values cx kind path field)

  (** A field of two values [f? int, unit]. *)
  let pair cx kind path field f =
    match opt cx kind path field with Some [a; b] -> Some (f a b) | _ -> None

  let loc cx kind path field =
    match all cx kind path field with (_, f) :: _ -> first_loc f | [] -> None
end

let metadata cx kind subj : metadata =
  let p = [subj] in
  { description = F.opt1 cx kind p "description" str;
    labels = F.table cx kind p "label" str str;
    annotations = F.table cx kind p "annotation" str str }

let assurance_of rows : assurance option =
  let level axis = List.assoc_opt axis rows |> Option.map enum in
  if rows = [] then None
  else Some { boot = level "boot"; operator = level "operator"; physical = level "physical" }

let axis_rows rows = List.map (fun (a, l) -> (const a, l)) rows

(* ============================================================ *)
(* kind: service                                                 *)
(* ============================================================ *)

(** What a provider offers its consumers, the [provides] of {!Types}: the
    fields of the block of its capability, the contract of the capability,
    written under its name ([database postgresql { user input(user). … }]),
    in the order of the field names. *)
let provides cx s : (string * string) list =
  match rows cx.model "service.capability" [s] with
  | ([c], _) :: _ ->
    let prefix = const c ^ "." in
    let n = String.length prefix in
    Hashtbl.fold (fun pred _ acc ->
      if String.length pred > n && String.sub pred 0 n = prefix
         && not (String.contains_from pred n '.') then
        let field = String.sub pred n (String.length pred - n) in
        List.filter_map (function
          | ([v], f) -> Some (field, render cx ?loc:(first_loc f) ~host_of:(const s) v)
          | _ -> None) (rows cx.model pred [s]) @ acc
      else acc) cx.model []
    |> List.sort compare
  | _ -> []

let service cx s : service_manifest =
  let k = "service" in
  let p = [s] in
  let sname = const s in
  let render_at ?host_of field v = render cx ?loc:(F.loc cx k p field) ?host_of v in
  let artifact =
    match F.values cx k p "artifact" with
    | [a] :: _ ->
      let q = [s; a] in
      Some { path = str a;
             sha256 = F.req1 cx k q "artifact.sha256" str;
             format = F.req1 cx k q "artifact.format" enum }
    | _ -> None in
  let consumes =
    F.list1 cx k p "consumes" Fun.id |> List.map (fun n ->
      let q = [s; n] in
      let service = F.opt1 cx k q "consumes.service" const in
      (* An inject is deduced (its template reads the provider): it has no
         location of its own, that of the consumption stands for it. *)
      let loc = match F.loc cx k q "consumes.inject" with
        | Some l -> Some l
        | None -> F.loc cx k [s; n] "consumes" in
      { name = const n;
        capability = F.opt1 cx k q "consumes.capability" const;
        service = Option.map dns service;
        provider = F.opt1 cx k q "consumes.provider" name;
        inject = F.table cx k q "consumes.inject" str
            (fun v -> render cx ?loc ?host_of:service v);
        mode = Option.value (F.opt1 cx k q "consumes.mode" const) ~default:"request" }) in
  let readiness =
    match F.indexed cx k p "readiness" (render_at "readiness") with
    | [] -> None
    | command ->
      Some { command;
             readiness_interval = Option.value (F.opt1 cx k p "readiness_interval" int) ~default:5;
             readiness_timeout = Option.value (F.opt1 cx k p "readiness_timeout" int) ~default:30 } in
  let security =
    F.opt1 cx k p "zone" const |> Option.map (fun zone ->
      let route_labels = F.list1 cx k p "route" Fun.id |> List.map (fun r ->
        let q = [s; r] in
        { route = str r;
          methods = F.list1 cx k q "route.method" str;
          public = F.flag cx k q "route.public";
          classification = F.opt1 cx k q "route.classification" const;
          categories = F.list1 cx k q "route.category" const;
          required_clearance = F.list1 cx k q "route.required_clearance" const }) in
      { zone; route_labels }) in
  let ports = F.list1 cx k p "port" Fun.id |> List.map (fun c ->
    { container = int c;
      protocol = Option.value (F.opt1 cx k [s; c] "port.protocol" const) ~default:"tcp" }) in
  let resources =
    let q field = F.pair cx k p field quantity in
    match q "memory_limit", q "memory_request", q "cpu_limit", q "cpu_request" with
    | None, None, None, None -> None
    | memory_limit, memory_request, cpu_limit, cpu_request ->
      Some { memory_limit; memory_request; cpu_limit; cpu_request } in
  let autoscaling =
    match F.opt1 cx k p "min_replicas" int, F.opt1 cx k p "max_replicas" int with
    | Some min_replicas, Some max_replicas ->
      Some { min_replicas; max_replicas;
             cpu_threshold = F.opt1 cx k p "cpu_threshold" int;
             memory_threshold = F.opt1 cx k p "memory_threshold" int }
    | _ -> None (* one without the other: E006 of the vocabulary *) in
  let health_check =
    F.opt1 cx k p "health_check" Fun.id |> Option.map (fun h ->
      let q = [s; h] in
      { path = str h;
        interval = Option.value (F.opt1 cx k q "health_check.interval" int) ~default:30;
        timeout = Option.value (F.opt1 cx k q "health_check.timeout" int) ~default:5;
        retries = Option.value (F.opt1 cx k q "health_check.retries" int) ~default:3 }) in
  let metrics =
    F.opt1 cx k p "metrics" Fun.id |> Option.map (fun m ->
      let q = [s; m] in
      { provider = const m;
        path = F.req1 cx k q "metrics.path" str;
        port = F.opt1 cx k q "metrics.port" int }) in
  let logging =
    match F.opt1 cx k p "log_format" const, F.opt1 cx k p "log_level" const with
    | None, None -> None
    | format, level ->
      Some { format = Option.value format ~default:"text";
             level = Option.value level ~default:"info" } in
  let storage = F.list1 cx k p "storage" Fun.id |> List.map (fun n ->
    let q = [s; n] in
    { st_name = const n;
      mount = F.req1 cx k q "storage.mount" str;
      st_class = F.req1 cx k q "storage.class" const;
      size = F.pair cx k q "storage.size" quantity;
      rebuild = F.opt1 cx k q "storage.rebuild" enum }) in
  let backup =
    F.opt1 cx k p "backup" Fun.id |> Option.map (fun sch ->
      let q = [s; sch] in
      { schedule = Some (str sch);
        retention = F.table cx k q "backup.retention" const int;
        pre = F.indexed cx k q "backup.pre" str;
        post = F.indexed cx k q "backup.post" str;
        verify = Option.value (F.opt1 cx k q "backup.verify" enum) ~default:"none" }) in
  let secrets = F.list1 cx k p "secret" Fun.id |> List.map (fun n ->
    let q = [s; n] in
    { sec_name = const n;
      sec_ref = F.opt1 cx k q "secret.ref" str;
      generate = F.pair cx k q "secret.generate" (fun kd len ->
          { gen_kind = const kd; gen_length = int len });
      rotate = F.pair cx k q "secret.rotate" (fun n u -> string_of_int (int n) ^ const u);
      sec_as = Option.value (F.opt1 cx k q "secret.as" const) ~default:"env" }) in
  let placement =
    let needs = F.list1 cx k p "need" const in
    let assurance = axis_rows (F.table cx k p "assurance" Fun.id Fun.id) in
    let spread = F.opt1 cx k p "spread" const in
    let affinity = F.list1 cx k p "affinity" name in
    let anti_affinity = F.list1 cx k p "anti_affinity" name in
    if needs = [] && assurance = [] && spread = None && affinity = [] && anti_affinity = []
    then None
    else Some { needs; pl_assurance = assurance_of assurance;
                spread = Option.value spread ~default:"none"; affinity; anti_affinity } in
  let exposure = F.list1 cx k p "exposure" Fun.id |> List.map (fun h ->
    let q = [s; h] in
    { hostname = str h;
      path_prefix = Option.value (F.opt1 cx k q "exposure.path_prefix" str) ~default:"/";
      exp_port = F.req1 cx k q "exposure.port" int;
      exp_protocol = Option.value (F.opt1 cx k q "exposure.protocol" const) ~default:"http";
      tls = Option.value (F.opt1 cx k q "exposure.tls" const) ~default:"acme" }) in
  { name = dns sname;
    runtime = F.req1 cx k p "runtime" const;
    artifact;
    capability = F.opt1 cx k p "capability" const;
    inputs = F.table cx k p "input" const (render_at "input");
    consumes;
    provides = provides cx s;
    readiness; security; ports;
    environment = F.table cx k p "environment" str (render_at "environment");
    resources;
    replicas = Option.value (F.opt1 cx k p "replicas" int) ~default:1;
    autoscaling; health_check; metrics; logging;
    metadata = metadata cx k s;
    storage; backup; secrets; placement; exposure }

(* ============================================================ *)
(* kind: pattern                                                 *)
(* ============================================================ *)

let constraint_error cx ?loc (e : Constraint_lang.error) =
  note cx ?loc "E052" []
    (if e.offset < 0 then e.message
     else Printf.sprintf "%s (at character %d)" e.message (e.offset + 1))

let pattern cx pt : pattern_manifest =
  let k = "pattern" in
  let p = [pt] in
  let levels = F.indexed cx k p "levels" const in
  let lattice =
    if levels = [] then None   (* categories without levels: E006 of the vocabulary *)
    else Some { levels; lat_categories = F.list1 cx k p "category" const } in
  let zones = F.list1 cx k p "zone" Fun.id |> List.map (fun z ->
    let q = [pt; z] in
    { zname = const z;
      zlevel = F.req1 cx k q "zone.level" const;
      zcategories = F.list1 cx k q "zone.category" const;
      boundary = Option.value (F.opt1 cx k q "zone.boundary" const) ~default:"firewall" }) in
  let pat_assurance =
    let rows = F.values cx k p "assurance" in
    let zone_names = List.sort_uniq compare
        (List.filter_map (function z :: _ -> Some (const z) | [] -> None) rows) in
    List.map (fun z ->
      (z, Option.get (assurance_of (List.filter_map (function
         | [z'; a; l] when const z' = z -> Some (const a, l) | _ -> None) rows))))
      zone_names in
  let constraints = F.list1 cx k p "constraint" Fun.id |> List.filter_map (fun c ->
    let q = [pt; c] in
    let expr_src = F.req1 cx k q "constraint.expr" str in
    match Constraint_lang.check_constraint expr_src with
    | Error e -> constraint_error cx ?loc:(F.loc cx k q "constraint.expr") e; None
    | Ok expr ->
      Some { cid = const c;
             cdescription = Option.value (F.opt1 cx k q "constraint.description" str) ~default:"";
             severity = Option.value (F.opt1 cx k q "constraint.severity" const) ~default:"hard";
             weight = F.opt1 cx k q "constraint.weight" int;
             expr_src; expr }) in
  let objectives direction = F.list1 cx k p direction Fun.id |> List.filter_map (fun t ->
    let q = [pt; t] in
    let term_src = str t in
    match Constraint_lang.check_objective term_src with
    | Error e -> constraint_error cx ?loc:(F.loc cx k q direction) e; None
    | Ok term ->
      Some { direction; term_src; term;
             priority = Option.value (F.opt1 cx k q (direction ^ ".priority") int) ~default:1;
             oweight = F.opt1 cx k q (direction ^ ".weight") int }) in
  { pat_name = name pt;
    pat_version = None;  (* that of its module: set by load *)
    lattice; zones; pat_assurance; constraints;
    objectives = objectives "minimize" @ objectives "maximize" }

(* ============================================================ *)
(* kind: stack                                                   *)
(* ============================================================ *)

let stack cx st : stack_manifest =
  let k = "stack" in
  let p = [st] in
  let services = F.list1 cx k p "service" Fun.id |> List.map (fun s ->
    let q = [st; s] in
    { ref_service = name s;
      replicas_override = F.opt1 cx k q "service.replicas" int;
      consumes_override = F.list1 cx k q "service.consumes" Fun.id |> List.map (fun n ->
        { consume_name = const n;
          provider = F.req1 cx k (q @ [n]) "service.consumes.provider" name }) }) in
  { name = name st;
    accept_experimental = F.flag cx k p "accept_experimental";
    services;
    infrastructure = F.opt1 cx k p "infrastructure" name }

(* ============================================================ *)
(* kind: infrastructure                                          *)
(* ============================================================ *)

let infrastructure cx i : infrastructure_manifest =
  let k = "infrastructure" in
  let p = [i] in
  let minimum_requirements =
    match F.opt1 cx k p "min_nodes" int, F.pair cx k p "total_ram" quantity,
          F.opt1 cx k p "total_cpu" int with
    | None, None, None -> None
    | min_nodes, total_ram, total_cpu -> Some { min_nodes; total_ram; total_cpu } in
  let nodes = F.list1 cx k p "node" Fun.id |> List.map (fun r ->
    let q = [i; r] in
    { role = const r;
      count = Option.value (F.opt1 cx k q "node.count" int) ~default:1;
      ram = F.pair cx k q "node.ram" quantity;
      cpu = F.opt1 cx k q "node.cpu" int;
      boot = F.opt1 cx k q "node.boot" enum;
      os_image = F.opt1 cx k q "node.os_image" str;
      os_sha256 = F.opt1 cx k q "node.os_sha256" str;
      isolated = F.flag cx k q "node.isolated";
      provisioning_profile = F.opt1 cx k q "node.provisioning_profile" name }) in
  let segments = F.list1 cx k p "segment" Fun.id |> List.map (fun n ->
    let q = [i; n] in
    { seg_name = const n;
      cidr = F.req1 cx k q "segment.cidr" str;
      vlan = F.opt1 cx k q "segment.vlan" int }) in
  let allow = F.values cx k p "allow" |> List.filter_map (function
    | [src; dst; c; s] ->
      Some { action = Allow; src_zone = const src; dst_zone = const dst;
             flow = Some (name c, name s); reason = None }
    | _ -> None) in
  let reasons = F.values cx k p "deny_reason" in
  let deny = F.values cx k p "deny" |> List.filter_map (function
    | [src; dst] ->
      let reason = List.find_map (function
        | [a; b; why] when const a = const src && const b = const dst -> Some (str why)
        | _ -> None) reasons in
      Some { action = Deny; src_zone = const src; dst_zone = const dst; flow = None; reason }
    | _ -> None) in
  let proposed_topology =
    if nodes = [] && segments = [] && allow = [] && deny = [] then None
    else Some { nodes; segments; firewall = allow @ deny } in
  { name = name i;
    backend = F.req1 cx k p "backend" enum;
    minimum_requirements; proposed_topology;
    warnings = F.list1 cx k p "warning" str;
    certificate = F.opt1 cx k p "certificate" str }

(* ============================================================ *)
(* kind: provisioning_profile                                    *)
(* ============================================================ *)

let provisioning_profile cx f : provisioning_profile_manifest =
  let k = "provisioning_profile" in
  let p = [f] in
  let pp_os = match F.values cx k p "os" with
    | [img] :: _ ->
      let q = [f; img] in
      let or_empty field = Option.value (F.opt1 cx k q field str) ~default:"" in
      { os_image_name = str img;
        os_url = F.req1 cx k q "os.url" str;
        os_sha256 = F.req1 cx k q "os.sha256" str;
        os_format = F.req1 cx k q "os.format" const;
        os_family = Option.value (F.opt1 cx k q "os.family" const) ~default:"debian";
        os_raw_zst_url = or_empty "os.raw_zst_url";
        os_raw_zst_sha256 = or_empty "os.raw_zst_sha256";
        os_bmap_url = or_empty "os.bmap_url" }
    | _ -> raise (Missing "provisioning_profile.os") in
  (* The bundles in the order of the list bundles, with the parameters of
     their sub-block bundle. *)
  let pp_bundles = F.indexed cx k p "bundles" Fun.id |> List.map (fun b ->
    let q = [f; b] in
    let bundle_params = F.list1 cx k q "bundle.param" Fun.id |> List.filter_map (fun x ->
      let r = q @ [x] in
      let loc = F.loc cx k r "bundle.param" in
      match F.opt1 cx k r "bundle.param.value" Fun.id,
            F.indexed cx k r "bundle.param.items" (param_of_text cx ?loc) with
      | Some v, _ -> Some (const x, param_of_text cx ?loc v)
      | None, (_ :: _ as items) -> Some (const x, PList items)
      | None, [] -> None (* neither: E007 of the vocabulary *)) in
    { bundle_name = name b; bundle_params }) in
  let pp_cloud_init_extra = F.opt1 cx k p "cloud_init_extra" str in
  { pp_name = name f;
    pp_os; pp_bundles; pp_cloud_init_extra;
    pp_assurance = assurance_of (axis_rows (F.table cx k p "assurance" Fun.id Fun.id)) }

(* ============================================================ *)
(* kind: bundle                                                  *)
(* ============================================================ *)

let param_type v = match const v with
  | "list_string" -> "list[string]"
  | "list_int" -> "list[int]"
  | t -> t

let bundle cx b : bundle_manifest =
  let k = "bundle" in
  let p = [b] in
  { bdl_name = name b;
    bdl_version = Option.value (F.opt1 cx k p "version" str) ~default:"0.1.0";
    bdl_description = Option.value (F.opt1 cx k p "description" str) ~default:"";
    bdl_params = F.list1 cx k p "param" Fun.id |> List.map (fun x ->
      let q = [b; x] in
      { param_name = const x;
        param_type = F.req1 cx k q "param.type" param_type;
        param_required = F.flag cx k q "param.required" });
    bdl_depends_on = F.list1 cx k p "depends_on" name;
    bdl_lifecycle = Option.value (F.opt1 cx k p "lifecycle" const) ~default:"install" }

(* ============================================================ *)
(* Stage-1 checks of Hamac                                       *)
(* ============================================================ *)

(** Experimental fields (W001): one finding per manifest and field, unless
    the stack writes accept_experimental ({!Stack_check.run}). *)
let experimental = [
  "service", [ "storage", "storage"; "backup", "backup"; "secret", "secrets";
               "need", "placement"; "assurance", "placement"; "spread", "placement";
               "affinity", "placement"; "anti_affinity", "placement";
               "exposure", "exposure"; "consumes.mode", "mode" ];
  "pattern", [ "assurance", "assurance"; "constraint", "constraints";
               "minimize", "objectives"; "maximize", "objectives" ];
  "infrastructure", [ "certificate", "certificate" ];
  "provisioning_profile", [ "assurance", "assurance" ];
  "bundle", [ "lifecycle", "lifecycle" ];
]

let note_experimental cx kind subj =
  let seen = Hashtbl.create 8 in
  List.iter (fun (field, label) ->
    match rows cx.model (kind ^ "." ^ field) [subj] with
    | (_, f) :: _ when not (Hashtbl.mem seen label) ->
      Hashtbl.add seen label ();
      note cx ?loc:(first_loc f) "W001" [label]
        (Printf.sprintf "'%s' is experimental: its meaning may change in a minor version \
                         (write accept_experimental in the stack to acknowledge)" label)
    | _ -> ()) (Option.value (List.assoc_opt kind experimental) ~default:[])

(** A manifest defined in several files (W003): the language merges the
    blocks of a subject, which serves as an overlay (a file that completes a
    manifest of another one), but also hides two independent definitions of
    the same name. *)
let note_overlay cx kind subj (f : fact) =
  match List.sort_uniq compare (List.map (fun (l : Diagnostic.loc) -> l.file) f.at) with
  | _ :: _ :: _ as files ->
    let loc = List.find_opt (fun (l : Diagnostic.loc) -> l.file = List.nth files 1) f.at in
    note cx ?loc "W003" []
      (Printf.sprintf "%s %s is defined in %s" kind (const subj)
         (match List.rev files with
          | last :: rest -> String.concat ", " (List.rev rest) ^ " and " ^ last
          | [] -> ""))
  | _ -> ()

(** The location of the LOAF fact that a path of {!Checks} designates, or
    that of the block. *)
let loc_of_path cx kind subj (m : manifest) (path : string list) : Diagnostic.loc option =
  let at field prefix = match rows cx.model (kind ^ "." ^ field) (subj :: prefix) with
    | (_, f) :: _ -> first_loc f | [] -> None in
  let nth l i f = match int_of_string_opt i with
    | Some i when i >= 0 && i < List.length l -> Some (f (List.nth l i))
    | _ -> None in
  let c x = Loaf.Fun (x, []) and s x = Loaf.Str x in
  let found = match m, path with
    | MService _, ("artifact" :: _) -> at "artifact" []
    | MService v, ("consumes" :: i :: _) ->
      Option.bind (nth v.consumes i (fun x -> c x.name)) (fun n -> at "consumes" [n])
    | MService _, ["resources"; f] -> at f []
    | MService _, ("health_check" :: _) -> at "health_check" []
    | MService v, ("storage" :: i :: rest) ->
      Option.bind (nth v.storage i (fun x -> c x.st_name)) (fun n ->
        match rest with
        | f :: _ -> (match at ("storage." ^ f) [n] with None -> at "storage" [n] | l -> l)
        | [] -> at "storage" [n])
    | MService v, ("secrets" :: i :: _) ->
      Option.bind (nth v.secrets i (fun x -> c x.sec_name)) (fun n -> at "secret" [n])
    | MService _, ("environment" :: key :: _) -> at "environment" [s key]
    | MService v, ("exposure" :: i :: _) ->
      Option.bind (nth v.exposure i (fun x -> s x.hostname)) (fun h -> at "exposure" [h])
    | MService v, ("security" :: "route_labels" :: i :: _) ->
      Option.bind (Option.bind v.security (fun sec -> nth sec.route_labels i (fun r -> s r.route)))
        (fun r -> at "route" [r])
    | MPattern _, ("assurance" :: z :: _) -> at "assurance" [c z]
    | MPattern v, ("zones" :: i :: _) ->
      Option.bind (nth v.zones i (fun z -> c z.zname)) (fun z -> at "zone" [z])
    | MProvisioningProfile _, ("os" :: _) -> at "os" []
    | MProvisioningProfile _, ("bundles" :: _) -> at "bundles" []
    | _ -> None in
  match found with
  | Some _ -> found
  | None -> (match rows cx.model kind [subj] with (_, f) :: _ -> first_loc f | [] -> None)

(* ============================================================ *)
(* Loading                                                       *)
(* ============================================================ *)

(** A manifest of a set of files, and the file of its block. *)
type source = {
  file: string;
  manifest: manifest;
}

(** A diagnostic of the language: the Hamac code that starts its message,
    otherwise the code of the language ([L002]), or [E001] for a lexical or
    syntax error. *)
let diagnostic_of_loaf (d : Loaf.Diag.t) : Diagnostic.t =
  let loc =
    if d.loc = Loaf.Loc.none then None
    else Some { Diagnostic.file = d.loc.file; line = d.loc.line; column = d.loc.column } in
  let m = d.message in
  let hamac_code =
    let n = String.length m in
    if n >= 6 && m.[0] = '[' && (m.[1] = 'E' || m.[1] = 'W') then
      match String.index_opt m ']' with
      | Some j when j > 2 && String.for_all (fun ch -> ch >= '0' && ch <= '9') (String.sub m 2 (j - 2)) ->
        Some (String.sub m 1 (j - 1), String.trim (String.sub m (j + 1) (n - j - 1)))
      | _ -> None
    else None in
  match hamac_code, d.code with
  | Some (code, message), _ -> Diagnostic.make ?loc code [] message
  | None, Some code -> Diagnostic.make ?loc code [] m
  | None, None -> Diagnostic.make ?loc "E001" [] m

let kinds = [
  "service", (fun cx s -> MService (service cx s));
  "pattern", (fun cx s -> MPattern (pattern cx s));
  "stack", (fun cx s -> MStack (stack cx s));
  "infrastructure", (fun cx s -> MInfrastructure (infrastructure cx s));
  "provisioning_profile", (fun cx s -> MProvisioningProfile (provisioning_profile cx s));
  "bundle", (fun cx s -> MBundle (bundle cx s));
]

(** The file a diagnostic is attributed to: that of its location, or the
    first file of the set. *)
let attribute files (d : Diagnostic.t) =
  match d.loc, files with
  | Some l, _ -> l.file
  | None, f :: _ -> f
  | None, [] -> ""

(** The files of a list of paths: a directory stands for the [.loaf] files
    it contains, at any depth ({!Loaf.sources}). *)
let sources = Loaf.sources

(** [load ~lib paths]: the manifests of a set of LOAF files ({!sources}), one per subject
    of a block of the vocabulary, in the order of the kinds then of the
    subjects, and the diagnostics of the set, attributed to their file and
    sorted. [lib] adds directories of modules to that of the vocabulary
    ({!vocabulary_dir}). The manifests are returned even when the model has
    errors, but not when the language refuses the files. *)
let load ?vocabulary ?(lib = []) (paths : string list)
  : source list * (string * Diagnostic.t) list =
  let files = Loaf.sources paths in
  let located ds = List.map (fun d -> (attribute files d, d)) ds in
  match vocabulary_dir ?vocabulary () with
  | Error msg -> ([], located [Diagnostic.make "E001" [] msg])
  | Ok vocab ->
    match Loaf.load ~lib:(vocab :: lib @ library_dirs ()) files with
    | exception Loaf.Diag.Error ds ->
      ([], located (List.sort_uniq compare (List.map diagnostic_of_loaf ds)))
    | exception Sys_error msg -> ([], located [Diagnostic.make "E001" [] ("cannot read file: " ^ msg)])
    | t ->
      let errors = List.sort_uniq compare (List.map diagnostic_of_loaf (Loaf.errors t)) in
      let model = model_of t in
      let cx = { model; diags = [] } in
      let modules = Loaf.modules t in
      let sources = List.concat_map (fun (kind, build) ->
        rows model kind [] |> List.filter_map (fun (args, fact) ->
          match args with
          | [subj] ->
            let file = match first_loc fact, files with
              | Some l, _ -> l.file
              | None, f :: _ -> f
              | None, [] -> "" in
            (match build cx subj with
             | exception Missing _ -> None   (* reported by the language (L007) *)
             | m ->
               let m = match m with
                 | MPattern p ->
                   MPattern { p with pat_version = List.find_map (fun (md : Loaf.module_) ->
                       if md.path = file then Some md.version else None) modules }
                 | m -> m in
               note_overlay cx kind subj fact;
               note_experimental cx kind subj;
               List.iter (fun (d : Diagnostic.t) ->
                 cx.diags <- { d with loc = loc_of_path cx kind subj m d.path } :: cx.diags)
                 (Checks.check m);
               Some { file; manifest = m })
          | _ -> None)) kinds in
      let diags = Diagnostic.sort (errors @ List.rev cx.diags) in
      (sources, located diags)

(** [asp ~lib paths]: the ASP form of a set of LOAF files ({!Loaf.asp}),
    the vocabulary and library directories found as by {!load}: one line
    per rule, for an application that adds its own rules (the planner). The
    files are expected to have been accepted by {!load}; a refusal is
    returned as its diagnostics. *)
let asp ?vocabulary ?(lib = []) (paths : string list)
  : (string list, (string * Diagnostic.t) list) result =
  let files = Loaf.sources paths in
  let located ds = List.map (fun d -> (attribute files d, d)) ds in
  match vocabulary_dir ?vocabulary () with
  | Error msg -> Error (located [Diagnostic.make "E001" [] msg])
  | Ok vocab ->
    match Loaf.asp ~lib:(vocab :: lib @ library_dirs ()) files with
    | lines -> Ok lines
    | exception Loaf.Diag.Error ds ->
      Error (located (List.sort_uniq compare (List.map diagnostic_of_loaf ds)))
    | exception Sys_error msg ->
      Error (located [Diagnostic.make "E001" [] ("cannot read file: " ^ msg)])
