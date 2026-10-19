(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** YAML manifest parser for hamac.

    Parses manifests into [Manifest_types.manifest] values, following
    doc/typst/manifest-spec.typ (format 1.1):

    - the format version is checked first, and decides which fields exist;
    - an unknown field is an error (fields starting with [x-] are
      extensions, kept out of the way);
    - every diagnostic carries a code of the specification's catalogue and
      the YAML path it is about.

    Parsing stops at the first structural error (a missing field, a wrong
    type). The checks that need a complete manifest ({!check}) report every
    finding at once. *)

open Manifest_types

(* ============================================================ *)
(* Context and errors                                            *)
(* ============================================================ *)

(** The highest format version this parser implements. *)
let supported_minor = 1
let supported_version = Printf.sprintf "1.%d" supported_minor

type cx = {
  minor: int;                              (** minor version of the manifest *)
  mutable diags: Diagnostic.t list;        (** non-fatal findings, newest first *)
}

let note cx code path message =
  cx.diags <- Diagnostic.make code path message :: cx.diags

type 'a result = ('a, Diagnostic.t) Stdlib.result

let error ?(code = "E007") path message = Error (Diagnostic.make code path message)

let ( let* ) = Stdlib.Result.bind

(* ============================================================ *)
(* YAML extraction helpers                                       *)
(* ============================================================ *)

let field_opt (name : string) (fields : (string * Yaml.value) list) : Yaml.value option =
  match List.assoc_opt name fields with
  | Some `Null -> None
  | v -> v

let require (path : string list) (name : string) (fields : (string * Yaml.value) list) : Yaml.value result =
  match field_opt name fields with
  | Some v -> Ok v
  | None -> error ~code:"E006" (path @ [name]) (Printf.sprintf "required field '%s' is missing" name)

let as_string (path : string list) (v : Yaml.value) : string result =
  match v with
  | `String s -> Ok s
  | `Float f ->
    (* YAML parses unquoted numbers as floats *)
    if Float.is_integer f then Ok (string_of_int (int_of_float f))
    else Ok (string_of_float f)
  | _ -> error path "expected a string"

let as_int (path : string list) (v : Yaml.value) : int result =
  match v with
  | `Float f when Float.is_integer f -> Ok (int_of_float f)
  | `String s -> (try Ok (int_of_string s) with _ -> error path "expected an integer")
  | _ -> error path "expected an integer"

let as_bool (path : string list) (v : Yaml.value) : bool result =
  match v with
  | `Bool b -> Ok b
  | `String "true" -> Ok true
  | `String "false" -> Ok false
  | _ -> error path "expected a boolean"

let as_list (path : string list) (v : Yaml.value) : Yaml.value list result =
  match v with
  | `A l -> Ok l
  | `Null -> Ok []
  | _ -> error path "expected a list"

let as_obj (path : string list) (v : Yaml.value) : (string * Yaml.value) list result =
  match v with
  | `O fields -> Ok fields
  | _ -> error path "expected an object"

let req_string path name fields =
  let* v = require path name fields in
  as_string (path @ [name]) v

let opt_string path name fields =
  match field_opt name fields with
  | None -> Ok None
  | Some v -> let* s = as_string (path @ [name]) v in Ok (Some s)

let string_or path name fields ~default =
  let* s = opt_string path name fields in
  Ok (Option.value s ~default)

let opt_int path name fields =
  match field_opt name fields with
  | None -> Ok None
  | Some v -> let* i = as_int (path @ [name]) v in Ok (Some i)

let int_or path name fields ~default =
  let* i = opt_int path name fields in
  Ok (Option.value i ~default)

let bool_or path name fields ~default =
  match field_opt name fields with
  | None -> Ok default
  | Some v -> as_bool (path @ [name]) v

let rec map_result f = function
  | [] -> Ok []
  | x :: rest -> let* y = f x in let* tl = map_result f rest in Ok (y :: tl)

let string_map path (v : Yaml.value) : (string * string) list result =
  match v with
  | `O fields ->
    map_result (fun (k, v) -> let* s = as_string (path @ [k]) v in Ok (k, s)) fields
  | `Null -> Ok []
  | _ -> error path "expected a key-value map"

let opt_map path name fields =
  match field_opt name fields with
  | None -> Ok []
  | Some v -> string_map (path @ [name]) v

let string_list path name fields =
  match field_opt name fields with
  | None -> Ok []
  | Some v ->
    let* items = as_list (path @ [name]) v in
    map_result (fun (i, x) -> as_string (path @ [name; string_of_int i]) x)
      (List.mapi (fun i x -> (i, x)) items)

let parse_opt name fields path parse_fn =
  match field_opt name fields with
  | None -> Ok None
  | Some v -> let* x = parse_fn (path @ [name]) v in Ok (Some x)

let parse_list name fields path parse_fn =
  match field_opt name fields with
  | None -> Ok []
  | Some v ->
    let* items = as_list (path @ [name]) v in
    map_result (fun (i, x) -> parse_fn (path @ [name; string_of_int i]) x)
      (List.mapi (fun i x -> (i, x)) items)

(* ============================================================ *)
(* Known fields                                                  *)
(* ============================================================ *)

(** A field of an object: its name, the minor version that introduced it,
    and whether it is experimental. *)
type field = { fname: string; since: int; experimental: bool }

let f ?(since = 0) ?(exp = false) fname = { fname; since; experimental = exp }

(** Refuse unknown fields (E003), fields newer than the manifest's version
    (E003), and note experimental ones (W001). *)
let known cx path (allowed : field list) (fields : (string * Yaml.value) list) : unit result =
  let rec go = function
    | [] -> Ok ()
    | (k, _) :: rest when String.length k > 2 && String.sub k 0 2 = "x-" -> go rest
    | (k, _) :: rest ->
      match List.find_opt (fun a -> a.fname = k) allowed with
      | None ->
        error ~code:"E003" (path @ [k])
          (Printf.sprintf "unknown field '%s' (expected one of: %s)" k
             (String.concat ", " (List.map (fun a -> a.fname)
                (List.filter (fun a -> a.since <= cx.minor) allowed))))
      | Some a when a.since > cx.minor ->
        error ~code:"E003" (path @ [k])
          (Printf.sprintf "field '%s' requires manifest_version 1.%d (this manifest is 1.%d)"
             k a.since cx.minor)
      | Some a ->
        if a.experimental then
          note cx "W001" (path @ [k])
            (Printf.sprintf "'%s' is experimental: its meaning may change in a minor version \
                             (set accept_experimental: true in the stack to acknowledge)" k);
        go rest
  in
  go fields

let obj cx path allowed v =
  let* fields = as_obj path v in
  let* () = known cx path allowed fields in
  Ok fields

(* ============================================================ *)
(* Envelope                                                      *)
(* ============================================================ *)

let envelope = [ f "manifest_version"; f "kind"; f "name"; f ~since:1 "metadata" ]

(* Character classes, written by hand rather than with [Str]: the
   library has no other use for regular expressions. *)
let is_lower c = c >= 'a' && c <= 'z'
let is_digit c = c >= '0' && c <= '9'

(** [first] for the first character, [inner] for the middle ones, [last]
    for the last one (a single character must satisfy [first] and [last]). *)
let shaped ~first ~inner ~last s =
  let n = String.length s in
  n > 0 && first s.[0] && last s.[n - 1]
  && (let ok = ref true in
      for i = 1 to n - 2 do if not (inner s.[i]) then ok := false done;
      !ok)

let alnum c = is_lower c || is_digit c

let dns_name = shaped ~first:is_lower ~last:alnum ~inner:(fun c -> alnum c || c = '-')
let dns_name_1_0 = shaped ~first:is_lower ~last:alnum ~inner:(fun c -> alnum c || c = '-' || c = '_')
let label_key = shaped ~first:alnum ~last:alnum
    ~inner:(fun c -> alnum c || c = '.' || c = '_' || c = '/' || c = '-')


let parse_name cx path fields =
  let* name = req_string path "name" fields in
  let p = path @ ["name"] in
  if String.length name <= 63 && dns_name name then Ok name
  else if cx.minor = 0 && String.length name <= 63 && dns_name_1_0 name then begin
    note cx "W002" p
      (Printf.sprintf "'%s' is not a DNS name ('_' is deprecated: a service name becomes \
                       a host name); manifest_version 1.1 refuses it" name);
    Ok name
  end
  else error ~code:"E004" p
      (Printf.sprintf "'%s' is not a DNS name (lowercase letters, digits and '-', \
                       starting with a letter, at most 63 characters)" name)

let parse_metadata cx path v =
  let* fields = obj cx path [ f "description"; f "labels"; f "annotations" ] v in
  let* description = opt_string path "description" fields in
  let* labels = opt_map path "labels" fields in
  let* () = map_result (fun (k, _) ->
      if label_key k then Ok ()
      else error ~code:"E007" (path @ ["labels"; k]) (Printf.sprintf "invalid label key '%s'" k))
      labels |> Result.map ignore in
  let* annotations = opt_map path "annotations" fields in
  Ok { description; labels; annotations }

let metadata_of cx path fields =
  let* m = parse_opt "metadata" fields path (parse_metadata cx) in
  Ok (Option.value m ~default:no_metadata)

(* ============================================================ *)
(* kind: service                                                 *)
(* ============================================================ *)

(** E007 unless [value] is one of [allowed]. *)
let one_of path what allowed value =
  if List.mem value allowed then Ok ()
  else error path (Printf.sprintf "%s '%s' (expected: %s)" what value (String.concat ", " allowed))

let artifact_formats =
  ["oci-image"; "native-linux-amd64"; "native-linux-arm64"; "incus-vm-image"; "incus-system-image"]

let runtimes = ["http"; "cli"; "batch"; "eventloop"; "custom"]

let parse_artifact cx path v =
  let* fields = obj cx path [ f "path"; f "sha256"; f "format" ] v in
  let* path_val = req_string path "path" fields in
  let* sha256 = req_string path "sha256" fields in
  let* format = req_string path "format" fields in
  let* () = one_of (path @ ["format"]) "format" artifact_formats format in
  Ok { path = path_val; sha256; format }

let parse_port cx path v =
  let* fields = obj cx path [ f "host"; f "container"; f "protocol" ] v in
  let* host =
    if cx.minor = 0 then let* v = require path "host" fields in
      let* h = as_int (path @ ["host"]) v in Ok (Some h)
    else opt_int path "host" fields in
  if cx.minor >= 1 && host <> None then
    note cx "W002" (path @ ["host"])
      "'host' is deprecated: publish the port with 'exposure' (a host port pins the \
       service to a machine)";
  let* container = let* v = require path "container" fields in as_int (path @ ["container"]) v in
  let* protocol = string_or path "protocol" fields ~default:"tcp" in
  Ok { host; container; protocol }

let parse_volume cx path v =
  let* fields = obj cx path [ f "host"; f "container"; f "read_only" ] v in
  let* host_path = req_string path "host" fields in
  let* container_path = req_string path "container" fields in
  let* read_only = bool_or path "read_only" fields ~default:false in
  Ok { host_path; container_path; read_only }

let parse_consumption cx path v =
  let* fields = obj cx path
      [ f "name"; f "capability"; f "service"; f "inject"; f ~since:1 ~exp:true "mode" ] v in
  let* name = req_string path "name" fields in
  let* capability = opt_string path "capability" fields in
  let* service = opt_string path "service" fields in
  let* inject = opt_map path "inject" fields in
  let* mode = string_or path "mode" fields ~default:"request" in
  if not (List.mem mode ["request"; "push"]) then
    error (path @ ["mode"]) (Printf.sprintf "mode '%s' (expected: request, push)" mode)
  else Ok { name; capability; service; inject; mode }

let parse_route_label cx path v =
  let* fields = obj cx path
      [ f "route"; f "required_clearance"; f ~since:1 "methods"; f ~since:1 "public";
        f ~since:1 "classification"; f ~since:1 "categories" ] v in
  let* route = req_string path "route" fields in
  let* required_clearance =
    if cx.minor = 0 then let* _ = require path "required_clearance" fields in
      string_list path "required_clearance" fields
    else string_list path "required_clearance" fields in
  let* methods = string_list path "methods" fields in
  let* public = bool_or path "public" fields ~default:false in
  let* classification = opt_string path "classification" fields in
  let* categories = string_list path "categories" fields in
  Ok { route; methods; public; classification; categories; required_clearance }

let parse_security cx path v =
  let* fields = obj cx path [ f "zone"; f "route_labels" ] v in
  let* zone = req_string path "zone" fields in
  let* route_labels = parse_list "route_labels" fields path (parse_route_label cx) in
  Ok { zone; route_labels }

let parse_resources cx path v =
  let* fields = obj cx path
      [ f "memory_limit"; f "memory_request"; f "cpu_limit"; f "cpu_request" ] v in
  let* memory_limit = opt_string path "memory_limit" fields in
  let* memory_request = opt_string path "memory_request" fields in
  let* cpu_limit = opt_string path "cpu_limit" fields in
  let* cpu_request = opt_string path "cpu_request" fields in
  Ok { memory_limit; memory_request; cpu_limit; cpu_request }

let parse_autoscaling cx path v =
  let* fields = obj cx path
      [ f "min_replicas"; f "max_replicas"; f "cpu_threshold"; f "memory_threshold" ] v in
  let* min_replicas = let* v = require path "min_replicas" fields in as_int (path @ ["min_replicas"]) v in
  let* max_replicas = let* v = require path "max_replicas" fields in as_int (path @ ["max_replicas"]) v in
  let* cpu_threshold = opt_int path "cpu_threshold" fields in
  let* memory_threshold = opt_int path "memory_threshold" fields in
  Ok { min_replicas; max_replicas; cpu_threshold; memory_threshold }

let parse_health_check cx path v =
  let* fields = obj cx path [ f "path"; f "interval"; f "timeout"; f "retries" ] v in
  let* hc_path = req_string path "path" fields in
  let* interval = int_or path "interval" fields ~default:30 in
  let* timeout = int_or path "timeout" fields ~default:5 in
  let* retries = int_or path "retries" fields ~default:3 in
  Ok { path = hc_path; interval; timeout; retries }

let parse_metrics cx path v =
  let* fields = obj cx path [ f "provider"; f "path"; f "port" ] v in
  let* provider = req_string path "provider" fields in
  let* m_path = req_string path "path" fields in
  let* port = opt_int path "port" fields in
  Ok { provider; path = m_path; port }

let parse_logging cx path v =
  let* fields = obj cx path [ f "format"; f "level" ] v in
  let* format = string_or path "format" fields ~default:"text" in
  let* level = string_or path "level" fields ~default:"info" in
  Ok { format; level }

let parse_readiness cx path v =
  let* fields = obj cx path [ f "command"; f "interval"; f "timeout" ] v in
  let* _ = require path "command" fields in
  let* command = string_list path "command" fields in
  let* readiness_interval = int_or path "interval" fields ~default:5 in
  let* readiness_timeout = int_or path "timeout" fields ~default:30 in
  Ok { command; readiness_interval; readiness_timeout }

let parse_storage_volume cx path v =
  let* fields = obj cx path [ f "name"; f "mount"; f "class"; f "size"; f "rebuild" ] v in
  let* st_name = req_string path "name" fields in
  let* mount = req_string path "mount" fields in
  let* st_class = req_string path "class" fields in
  let* () =
    if List.mem st_class ["ephemeral"; "local"; "replicated"] then Ok ()
    else error (path @ ["class"])
        (Printf.sprintf "class '%s' (expected: ephemeral, local, replicated; \
                         object storage is consumed with capability: object-storage)" st_class) in
  let* size = opt_string path "size" fields in
  let* rebuild = opt_string path "rebuild" fields in
  let* () = match rebuild with
    | Some r when not (List.mem r ["from-backup"; "from-object"; "from-replica"; "none"]) ->
      error (path @ ["rebuild"])
        (Printf.sprintf "rebuild '%s' (expected: from-backup, from-object, from-replica, none)" r)
    | _ -> Ok () in
  Ok { st_name; mount; st_class; size; rebuild }

let parse_backup cx path v =
  let* fields = obj cx path [ f "schedule"; f "retention"; f "consistency"; f "verify" ] v in
  let* schedule = opt_string path "schedule" fields in
  let* retention = match field_opt "retention" fields with
    | None -> Ok []
    | Some v ->
      let p = path @ ["retention"] in
      let* kv = obj cx p [ f "hourly"; f "daily"; f "weekly"; f "monthly"; f "yearly" ] v in
      map_result (fun (k, v) -> let* n = as_int (p @ [k]) v in Ok (k, n)) kv in
  let* pre, post = match field_opt "consistency" fields with
    | None -> Ok ([], [])
    | Some v ->
      let p = path @ ["consistency"] in
      let* c = obj cx p [ f "pre"; f "post" ] v in
      let* pre = string_list p "pre" c in
      let* post = string_list p "post" c in
      Ok (pre, post) in
  let* verify = string_or path "verify" fields ~default:"none" in
  if not (List.mem verify ["none"; "restore-test"]) then
    error (path @ ["verify"]) (Printf.sprintf "verify '%s' (expected: none, restore-test)" verify)
  else Ok { schedule; retention; pre; post; verify }

let parse_secret cx path v =
  let* fields = obj cx path [ f "name"; f "ref"; f "generate"; f "rotate"; f "as" ] v in
  let* sec_name = req_string path "name" fields in
  let* sec_ref = opt_string path "ref" fields in
  let* generate = match field_opt "generate" fields with
    | None -> Ok None
    | Some v ->
      let p = path @ ["generate"] in
      let* g = obj cx p [ f "kind"; f "length" ] v in
      let* gen_kind = string_or p "kind" g ~default:"alnum" in
      let* gen_length = int_or p "length" g ~default:32 in
      Ok (Some { gen_kind; gen_length }) in
  let* rotate = opt_string path "rotate" fields in
  let* sec_as = string_or path "as" fields ~default:"env" in
  if not (List.mem sec_as ["env"; "file"]) then
    error (path @ ["as"]) (Printf.sprintf "as '%s' (expected: env, file)" sec_as)
  else Ok { sec_name; sec_ref; generate; rotate; sec_as }

let axes = [
  "boot", ["none"; "provider-vtpm"; "confidential-vm"; "measured-tpm2"];
  "operator", ["any"; "eu"; "secnumcloud"; "self"];
  "physical", ["third-party"; "dedicated-rack"; "site"];
]

let parse_assurance cx path v =
  let* fields = obj cx path [ f "boot"; f "operator"; f "physical" ] v in
  let axis name =
    let* value = opt_string path name fields in
    match value with
    | Some x when not (List.mem x (List.assoc name axes)) ->
      error (path @ [name]) (Printf.sprintf "%s '%s' (expected, from weakest to strongest: %s)"
                               name x (String.concat " < " (List.assoc name axes)))
    | _ -> Ok value in
  let* boot = axis "boot" in
  let* operator = axis "operator" in
  let* physical = axis "physical" in
  Ok { boot; operator; physical }

let parse_placement cx path v =
  let* fields = obj cx path
      [ f "needs"; f "assurance"; f "spread"; f "affinity"; f "anti_affinity" ] v in
  let* needs = string_list path "needs" fields in
  let* pl_assurance = parse_opt "assurance" fields path (parse_assurance cx) in
  let* spread = string_or path "spread" fields ~default:"none" in
  let* () = if List.mem spread ["none"; "host"; "failure_domain"] then Ok ()
    else error (path @ ["spread"]) (Printf.sprintf "spread '%s' (expected: none, host, failure_domain)" spread) in
  let* affinity = string_list path "affinity" fields in
  let* anti_affinity = string_list path "anti_affinity" fields in
  Ok { needs; pl_assurance; spread; affinity; anti_affinity }

let parse_exposure cx path v =
  let* fields = obj cx path
      [ f "hostname"; f "path_prefix"; f "port"; f "protocol"; f "tls" ] v in
  let* hostname = req_string path "hostname" fields in
  let* path_prefix = string_or path "path_prefix" fields ~default:"/" in
  let* exp_port = let* v = require path "port" fields in as_int (path @ ["port"]) v in
  let* exp_protocol = string_or path "protocol" fields ~default:"http" in
  let* tls = string_or path "tls" fields ~default:"acme" in
  let* () = if List.mem exp_protocol ["http"; "tcp"] then Ok ()
    else error (path @ ["protocol"]) (Printf.sprintf "protocol '%s' (expected: http, tcp)" exp_protocol) in
  let* () = if List.mem tls ["acme"; "internal"; "passthrough"] then Ok ()
    else error (path @ ["tls"]) (Printf.sprintf "tls '%s' (expected: acme, internal, passthrough)" tls) in
  Ok { hostname; path_prefix; exp_port; exp_protocol; tls }

let service_fields = envelope @ [
  f "runtime"; f "artifact"; f "capability"; f "inputs"; f "consumes"; f "provides";
  f "readiness"; f "security"; f "ports"; f "volumes"; f "environment"; f "resources";
  f "replicas"; f "autoscaling"; f "health_check"; f "metrics"; f "logging";
  f ~since:1 ~exp:true "storage"; f ~since:1 ~exp:true "backup";
  f ~since:1 ~exp:true "secrets"; f ~since:1 ~exp:true "placement";
  f ~since:1 ~exp:true "exposure";
]

let parse_service_manifest cx path fields =
  let* () = known cx path service_fields fields in
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = parse_name cx path fields in
  let* metadata = metadata_of cx path fields in
  let* runtime = req_string path "runtime" fields in
  let* () = one_of (path @ ["runtime"]) "runtime" runtimes runtime in
  let* artifact = parse_opt "artifact" fields path (parse_artifact cx) in
  let* capability = opt_string path "capability" fields in
  let* inputs = opt_map path "inputs" fields in
  let* consumes = parse_list "consumes" fields path (parse_consumption cx) in
  let* provides = opt_map path "provides" fields in
  let* readiness = parse_opt "readiness" fields path (parse_readiness cx) in
  let* security = parse_opt "security" fields path (parse_security cx) in
  let* ports = parse_list "ports" fields path (parse_port cx) in
  let* volumes = parse_list "volumes" fields path (parse_volume cx) in
  if cx.minor >= 1 && volumes <> [] then
    note cx "W002" (path @ ["volumes"])
      "'volumes' is deprecated: declare file systems in 'storage', files in object storage";
  let* environment = opt_map path "environment" fields in
  let* resources = parse_opt "resources" fields path (parse_resources cx) in
  let* replicas = int_or path "replicas" fields ~default:1 in
  let* autoscaling = parse_opt "autoscaling" fields path (parse_autoscaling cx) in
  let* health_check = parse_opt "health_check" fields path (parse_health_check cx) in
  let* metrics = parse_opt "metrics" fields path (parse_metrics cx) in
  let* logging = parse_opt "logging" fields path (parse_logging cx) in
  let* storage = parse_list "storage" fields path (parse_storage_volume cx) in
  let* backup = parse_opt "backup" fields path (parse_backup cx) in
  let* secrets = parse_list "secrets" fields path (parse_secret cx) in
  let* placement = parse_opt "placement" fields path (parse_placement cx) in
  let* exposure = parse_list "exposure" fields path (parse_exposure cx) in
  Ok {
    manifest_version; name; runtime; artifact; capability; inputs;
    consumes; provides; readiness; security; ports; volumes;
    environment; resources; replicas; autoscaling;
    health_check; metrics; logging;
    metadata; storage; backup; secrets; placement; exposure;
  }

(* ============================================================ *)
(* kind: pattern                                                 *)
(* ============================================================ *)

let parse_lattice cx path v =
  let* fields = obj cx path [ f "levels"; f "categories" ] v in
  let* _ = require path "levels" fields in
  let* levels = string_list path "levels" fields in
  let* lat_categories = string_list path "categories" fields in
  if levels = [] then error (path @ ["levels"]) "a lattice needs at least one level"
  else Ok { levels; lat_categories }

let parse_zone_decl cx path v =
  let* fields = obj cx path [ f "name"; f "level"; f "categories"; f "boundary" ] v in
  let* zname = req_string path "name" fields in
  let* zlevel = req_string path "level" fields in
  let* zcategories = string_list path "categories" fields in
  let* boundary = string_or path "boundary" fields ~default:"firewall" in
  if not (List.mem boundary ["firewall"; "diode"]) then
    error (path @ ["boundary"]) (Printf.sprintf "boundary '%s' (expected: firewall, diode)" boundary)
  else Ok { zname; zlevel; zcategories; boundary }

let constraint_error path (e : Constraint_lang.error) =
  error ~code:"E052" path
    (if e.offset < 0 then e.message
     else Printf.sprintf "%s (at character %d)" e.message (e.offset + 1))

let parse_constraint cx path v =
  let* fields = obj cx path
      [ f "id"; f "description"; f "severity"; f "weight"; f "expr" ] v in
  let* cid = req_string path "id" fields in
  let* cdescription = string_or path "description" fields ~default:"" in
  let* severity = string_or path "severity" fields ~default:"hard" in
  let* () = if List.mem severity ["hard"; "soft"] then Ok ()
    else error (path @ ["severity"]) (Printf.sprintf "severity '%s' (expected: hard, soft)" severity) in
  let* weight = opt_int path "weight" fields in
  let* expr_src = req_string path "expr" fields in
  match Constraint_lang.check_constraint expr_src with
  | Error e -> constraint_error (path @ ["expr"]) e
  | Ok expr -> Ok { cid; cdescription; severity; weight; expr_src; expr }

let parse_objective cx path v =
  let* fields = obj cx path [ f "minimize"; f "maximize"; f "priority"; f "weight" ] v in
  let* direction, term_src = match field_opt "minimize" fields, field_opt "maximize" fields with
    | Some t, None -> let* s = as_string (path @ ["minimize"]) t in Ok ("minimize", s)
    | None, Some t -> let* s = as_string (path @ ["maximize"]) t in Ok ("maximize", s)
    | _ -> error ~code:"E006" path "an objective has exactly one of 'minimize' and 'maximize'" in
  let* priority = int_or path "priority" fields ~default:1 in
  let* oweight = opt_int path "weight" fields in
  match Constraint_lang.check_objective term_src with
  | Error e -> constraint_error (path @ [direction]) e
  | Ok term -> Ok { direction; term_src; term; priority; oweight }

let pattern_fields = envelope @ [
  f "version"; f "extends"; f "lattice"; f "zones";
  f ~exp:true "assurance"; f ~exp:true "constraints"; f ~exp:true "objectives";
]

let parse_pattern_manifest cx path fields =
  let* () = known cx path pattern_fields fields in
  let* pat_manifest_version = req_string path "manifest_version" fields in
  let* pat_name = parse_name cx path fields in
  let* _ = metadata_of cx path fields in
  let* pat_version = req_string path "version" fields in
  let* extends = string_list path "extends" fields in
  let* lattice = parse_opt "lattice" fields path (parse_lattice cx) in
  let* zones = parse_list "zones" fields path (parse_zone_decl cx) in
  let* pat_assurance = match field_opt "assurance" fields with
    | None -> Ok []
    | Some v ->
      let p = path @ ["assurance"] in
      let* kv = as_obj p v in
      map_result (fun (z, v) -> let* a = parse_assurance cx (p @ [z]) v in Ok (z, a)) kv in
  let* constraints = parse_list "constraints" fields path (parse_constraint cx) in
  let* objectives = parse_list "objectives" fields path (parse_objective cx) in
  Ok { pat_manifest_version; pat_name; pat_version; extends; lattice; zones;
       pat_assurance; constraints; objectives }

(* ============================================================ *)
(* kind: stack                                                   *)
(* ============================================================ *)

let parse_stack_consume_override cx path v =
  let* fields = obj cx path [ f "name"; f "provider" ] v in
  let* consume_name = req_string path "name" fields in
  let* provider = req_string path "provider" fields in
  Ok { consume_name; provider }

let parse_stack_service_ref cx path v =
  let* fields = obj cx path [ f "ref"; f "replicas"; f "consumes" ] v in
  let* ref_path = req_string path "ref" fields in
  let* replicas_override = opt_int path "replicas" fields in
  let* consumes_override = parse_list "consumes" fields path (parse_stack_consume_override cx) in
  Ok { ref_path; replicas_override; consumes_override }

let stack_fields = envelope @ [
  f "services"; f "infrastructure"; f ~since:1 "patterns"; f ~since:1 "accept_experimental";
]

let parse_stack_manifest cx path fields =
  let* () = known cx path stack_fields fields in
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = parse_name cx path fields in
  let* _ = metadata_of cx path fields in
  let* patterns = string_list path "patterns" fields in
  let* accept_experimental = bool_or path "accept_experimental" fields ~default:false in
  let* services = parse_list "services" fields path (parse_stack_service_ref cx) in
  let* infrastructure = opt_string path "infrastructure" fields in
  Ok { manifest_version; name; patterns; accept_experimental; services; infrastructure }

(* ============================================================ *)
(* kind: infrastructure                                          *)
(* ============================================================ *)

let parse_infra_node cx path v =
  let* fields = obj cx path
      [ f "role"; f "count"; f "ram"; f "cpu"; f "boot"; f "os"; f "isolated";
        f "provisioning_profile" ] v in
  let* role = req_string path "role" fields in
  let* count = int_or path "count" fields ~default:1 in
  let* ram = opt_string path "ram" fields in
  let* cpu = opt_int path "cpu" fields in
  let* boot = opt_string path "boot" fields in
  let* os_image, os_sha256 = match field_opt "os" fields with
    | None -> Ok (None, None)
    | Some v ->
      let p = path @ ["os"] in
      let* os = obj cx p [ f "image"; f "sha256" ] v in
      let* image = opt_string p "image" os in
      let* sha = opt_string p "sha256" os in
      Ok (image, sha) in
  let* isolated = bool_or path "isolated" fields ~default:false in
  let* provisioning_profile = opt_string path "provisioning_profile" fields in
  Ok { role; count; ram; cpu; boot; os_image; os_sha256; isolated; provisioning_profile }

let parse_network_segment cx path v =
  let* fields = obj cx path [ f "name"; f "cidr"; f "vlan" ] v in
  let* seg_name = req_string path "name" fields in
  let* cidr = req_string path "cidr" fields in
  let* vlan = opt_int path "vlan" fields in
  Ok { seg_name; cidr; vlan }

let parse_firewall_rule path v =
  let* rule = as_string path v in
  match firewall_rule_of_string rule with
  | Ok r -> Ok r
  | Error msg -> error path msg

let parse_infra_topology cx path v =
  let* fields = obj cx path [ f "nodes"; f "network" ] v in
  let* nodes = parse_list "nodes" fields path (parse_infra_node cx) in
  let* segments, firewall = match field_opt "network" fields with
    | None -> Ok ([], [])
    | Some v ->
      let p = path @ ["network"] in
      let* net = obj cx p [ f "segments"; f "firewall" ] v in
      let* segments = parse_list "segments" net p (parse_network_segment cx) in
      let* firewall = parse_list "firewall" net p parse_firewall_rule in
      Ok (segments, firewall) in
  Ok { nodes; segments; firewall }

let parse_infra_requirements cx path v =
  let* fields = obj cx path [ f "nodes"; f "total_ram"; f "total_cpu" ] v in
  let* min_nodes = opt_int path "nodes" fields in
  let* total_ram = opt_string path "total_ram" fields in
  let* total_cpu = opt_int path "total_cpu" fields in
  Ok { min_nodes; total_ram; total_cpu }

let infrastructure_fields = envelope @ [
  f "backend"; f "minimum_requirements"; f "proposed_topology"; f "warnings";
  f ~since:1 ~exp:true "certificate";
]

let parse_infrastructure_manifest cx path fields =
  let* () = known cx path infrastructure_fields fields in
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = parse_name cx path fields in
  let* _ = metadata_of cx path fields in
  let* backend = req_string path "backend" fields in
  let* minimum_requirements = parse_opt "minimum_requirements" fields path (parse_infra_requirements cx) in
  let* proposed_topology = parse_opt "proposed_topology" fields path (parse_infra_topology cx) in
  let* warnings = string_list path "warnings" fields in
  let* certificate = opt_string path "certificate" fields in
  Ok { manifest_version; name; backend; minimum_requirements; proposed_topology;
       warnings; certificate }

(* ============================================================ *)
(* kind: provisioning_profile                                    *)
(* ============================================================ *)

let parse_os_image_spec cx path v =
  let* fields = obj cx path
      [ f "image"; f "url"; f "sha256"; f "format"; f "family";
        f "raw_zst_url"; f "raw_zst_sha256"; f "bmap_url" ] v in
  let* os_image_name = req_string path "image" fields in
  let* os_url = req_string path "url" fields in
  let* os_sha256 = req_string path "sha256" fields in
  let* os_format = req_string path "format" fields in
  (* défaut : famille apt (debian/ubuntu) *)
  let* os_family = string_or path "family" fields ~default:"debian" in
  (* Assets dérivés pour install physique (bmaptool) — optionnels, vides si
     absents. Le qcow2 ci-dessus reste la référence. *)
  let* os_raw_zst_url = string_or path "raw_zst_url" fields ~default:"" in
  let* os_raw_zst_sha256 = string_or path "raw_zst_sha256" fields ~default:"" in
  let* os_bmap_url = string_or path "bmap_url" fields ~default:"" in
  Ok { os_image_name; os_url; os_sha256; os_format; os_family;
       os_raw_zst_url; os_raw_zst_sha256; os_bmap_url }

(** Un bundle_ref : name + params (params bruts, transmis tels quels au
    générateur Jinja2). *)
let parse_bundle_ref cx path v =
  let* fields = obj cx path [ f "name"; f "params" ] v in
  let* bundle_name = req_string path "name" fields in
  let* bundle_params = match field_opt "params" fields with
    | None -> Ok []
    | Some v -> as_obj (path @ ["params"]) v in
  Ok { bundle_name; bundle_params }

let profile_fields = envelope @ [
  f "os"; f "bundles"; f "cloud_init_extra"; f ~since:1 ~exp:true "assurance";
]

let parse_provisioning_profile_manifest cx path fields =
  let* () = known cx path profile_fields fields in
  let* pp_manifest_version = req_string path "manifest_version" fields in
  let* pp_name = parse_name cx path fields in
  let* _ = metadata_of cx path fields in
  let* pp_os = let* v = require path "os" fields in parse_os_image_spec cx (path @ ["os"]) v in
  let* pp_bundles = parse_list "bundles" fields path (parse_bundle_ref cx) in
  let pp_cloud_init_extra = field_opt "cloud_init_extra" fields in
  let* pp_assurance = parse_opt "assurance" fields path (parse_assurance cx) in
  Ok { pp_manifest_version; pp_name; pp_os; pp_bundles; pp_cloud_init_extra; pp_assurance }

(* ============================================================ *)
(* kind: bundle                                                  *)
(* ============================================================ *)

let bundle_param_types = ["string"; "int"; "bool"; "list[string]"; "list[int]"; "object"]

let parse_bundle_param_spec cx path (name, v) =
  let p = path @ [name] in
  let* fields = obj cx p [ f "type"; f "required" ] v in
  let* param_type = req_string p "type" fields in
  let* param_required = bool_or p "required" fields ~default:false in
  if not (List.mem param_type bundle_param_types) then
    error (p @ ["type"]) (Printf.sprintf "unknown parameter type '%s' (expected: %s)"
                            param_type (String.concat ", " bundle_param_types))
  else Ok { param_name = name; param_type; param_required }

let bundle_fields = envelope @ [
  f "version"; f "description"; f "params"; f "depends_on"; f ~since:1 ~exp:true "lifecycle";
]

let parse_bundle_manifest cx path fields =
  let* () = known cx path bundle_fields fields in
  let* bdl_manifest_version = req_string path "manifest_version" fields in
  let* bdl_name = parse_name cx path fields in
  let* _ = metadata_of cx path fields in
  let* bdl_version = string_or path "version" fields ~default:"0.1.0" in
  let* bdl_description = string_or path "description" fields ~default:"" in
  let* bdl_params = match field_opt "params" fields with
    | None -> Ok []
    | Some (`O kv) -> map_result (parse_bundle_param_spec cx (path @ ["params"])) kv
    | Some _ -> error (path @ ["params"]) "expected an object mapping name → spec" in
  let* bdl_depends_on = string_list path "depends_on" fields in
  let* bdl_lifecycle = string_or path "lifecycle" fields ~default:"install" in
  if not (List.mem bdl_lifecycle ["install"; "converge"]) then
    error (path @ ["lifecycle"]) (Printf.sprintf "lifecycle '%s' (expected: install, converge)" bdl_lifecycle)
  else
    Ok { bdl_manifest_version; bdl_name; bdl_version; bdl_description;
         bdl_params; bdl_depends_on; bdl_lifecycle }

(* ============================================================ *)
(* Top-level parser                                              *)
(* ============================================================ *)

let kinds = ["service"; "pattern"; "stack"; "infrastructure"; "provisioning_profile"; "bundle"]

(** The minor version of a manifest, or E002. *)
let parse_version fields : int result =
  let p = ["manifest_version"] in
  match field_opt "manifest_version" fields with
  | None -> error ~code:"E002" p "required field 'manifest_version' is missing"
  | Some v ->
    let* s = as_string p v in
    match String.split_on_char '.' s with
    | [maj; min] when (try int_of_string maj >= 0 && int_of_string min >= 0 with _ -> false) ->
      let maj = int_of_string maj and min = int_of_string min in
      if maj <> 1 || min > supported_minor then
        error ~code:"E002" p
          (Printf.sprintf "manifest_version %s is not supported (this hamac implements %s)"
             s supported_version)
      else Ok min
    | _ -> error ~code:"E002" p
             (Printf.sprintf "manifest_version '%s' is malformed (expected \"<major>.<minor>\")" s)

let parse_manifest_cx (yaml : Yaml.value) : (manifest * cx, Diagnostic.t) Stdlib.result =
  let* fields = match yaml with
    | `O fields -> Ok fields
    | _ -> error ~code:"E001" [] "a manifest is a YAML object" in
  let* minor = parse_version fields in
  let cx = { minor; diags = [] } in
  let* kind = match field_opt "kind" fields with
    | Some v -> as_string ["kind"] v
    | None when minor = 0 ->
      note cx "W002" ["kind"] "a manifest without 'kind' is read as a service (deprecated)";
      Ok "service"
    | None -> error ~code:"E006" ["kind"] "required field 'kind' is missing" in
  let path = [] in
  let* m = match kind with
    | "service" -> let* m = parse_service_manifest cx path fields in Ok (MService m)
    | "pattern" when minor >= 1 ->
      let* m = parse_pattern_manifest cx path fields in Ok (MPattern m)
    | "stack" -> let* m = parse_stack_manifest cx path fields in Ok (MStack m)
    | "infrastructure" ->
      let* m = parse_infrastructure_manifest cx path fields in Ok (MInfrastructure m)
    | "provisioning_profile" ->
      let* m = parse_provisioning_profile_manifest cx path fields in Ok (MProvisioningProfile m)
    | "bundle" -> let* m = parse_bundle_manifest cx path fields in Ok (MBundle m)
    | "pattern" ->
      error ~code:"E005" ["kind"] "kind 'pattern' requires manifest_version 1.1"
    | other ->
      error ~code:"E005" ["kind"]
        (Printf.sprintf "unknown manifest kind '%s' (expected: %s)" other (String.concat ", " kinds)) in
  Ok (m, cx)

let parse_manifest yaml = Result.map fst (parse_manifest_cx yaml)

(* ============================================================ *)
(* Checks on a complete manifest (stage 1)                       *)
(* ============================================================ *)

let is_sha256 s =
  String.length s = 64
  && String.for_all (fun c -> is_digit c || (c >= 'a' && c <= 'f')) (String.lowercase_ascii s)

(** Bytes of a memory quantity ([512Mi], [1Gi]), or millicores of a CPU
    quantity ([2], [0.5], [500m]). [None] if malformed. *)
let quantity_value ~cpu (s : string) : int option =
  let split suffixes =
    List.find_map (fun (u, m) ->
      let n = String.length s and k = String.length u in
      if n > k && String.sub s (n - k) k = u then Some (String.sub s 0 (n - k), m) else None)
      suffixes in
  let units =
    if cpu then (match split ["m", 1.] with Some x -> Some x | None -> Some (s, 1000.))
    else split ["Ki", 1024.; "Mi", 1048576.; "Gi", 1073741824.; "Ti", 1099511627776.] in
  match units with
  | None -> None
  | Some (number, scale) ->
    match float_of_string_opt number with
    | Some x when x >= 0. && Float.is_finite x -> Some (int_of_float (x *. scale))
    | _ -> None

let duplicates names =
  let rec go seen = function
    | [] -> []
    | (i, x) :: rest -> if List.mem x seen then (i, x) :: go seen rest else go (x :: seen) rest
  in go [] (List.mapi (fun i x -> (i, x)) names)

let ends_with ~suffix s =
  let n = String.length s and k = String.length suffix in
  n >= k && String.sub s (n - k) k = suffix

let secret_like_key k =
  List.exists (fun suffix -> ends_with ~suffix k) ["PASSWORD"; "TOKEN"; "SECRET"; "_KEY"]

(** Names [x] of the [{secret.x}] references of a template. *)
let template_secrets s =
  let prefix = "{secret." in
  let k = String.length prefix in
  let rec go i acc =
    match String.index_from_opt s i '{' with
    | None -> List.rev acc
    | Some j when j + k <= String.length s && String.sub s j k = prefix ->
      (match String.index_from_opt s (j + k) '}' with
       | None -> List.rev acc
       | Some close -> go (close + 1) (String.sub s (j + k) (close - j - k) :: acc))
    | Some j -> go (j + 1) acc
  in go 0 []

let check_service cx (svc : service_manifest) =
  let e = note cx in
  (match svc.artifact with
   | Some a ->
     if not (is_sha256 a.sha256) then
       e "E011" ["artifact"; "sha256"] "expected 64 hexadecimal characters (SHA-256)";
     if a.format = "oci-image" && not (String.contains a.path '@') then
       e "W010" ["artifact"; "path"]
         (Printf.sprintf "OCI image '%s' is not pinned by digest (@sha256:…)" a.path)
   | None -> ());
  List.iter (fun (i, n) ->
    e "E012" ["consumes"; string_of_int i; "name"] (Printf.sprintf "duplicate consumes name '%s'" n))
    (duplicates (List.map (fun (c : consumption) -> c.name) svc.consumes));
  List.iteri (fun i (c : consumption) ->
    match c.capability, c.service with
    | None, None | Some _, Some _ ->
      e "E013" ["consumes"; string_of_int i]
        (Printf.sprintf "consumes '%s': exactly one of 'capability' and 'service'" c.name)
    | _ -> ()) svc.consumes;
  (match svc.resources with
   | None -> ()
   | Some r ->
     let q ~cpu field v = match v with
       | None -> None
       | Some s -> (match quantity_value ~cpu s with
           | Some x -> Some x
           | None ->
             e "E015" ["resources"; field]
               (Printf.sprintf "invalid quantity '%s' (%s)" s
                  (if cpu then "cores, or millicores like 500m" else "Ki, Mi, Gi or Ti"));
             None) in
     let mr = q ~cpu:false "memory_request" r.memory_request
     and ml = q ~cpu:false "memory_limit" r.memory_limit
     and cr = q ~cpu:true "cpu_request" r.cpu_request
     and cl = q ~cpu:true "cpu_limit" r.cpu_limit in
     (match mr, ml with
      | Some a, Some b when a > b -> e "E014" ["resources"; "memory_request"] "request above its limit"
      | _ -> ());
     (match cr, cl with
      | Some a, Some b when a > b -> e "E014" ["resources"; "cpu_request"] "request above its limit"
      | _ -> ()));
  if svc.replicas < 1 then e "E016" ["replicas"] "replicas must be at least 1";
  (match svc.autoscaling with
   | Some a when a.min_replicas < 1 || a.min_replicas > a.max_replicas ->
     e "E016" ["autoscaling"] "expected 1 ≤ min_replicas ≤ max_replicas"
   | _ -> ());
  (match svc.health_check with
   | Some h when h.timeout >= h.interval ->
     e "W011" ["health_check"; "timeout"] "timeout is not shorter than interval"
   | _ -> ());
  (* Storage *)
  if svc.volumes <> [] && svc.storage <> [] then
    e "E030" ["volumes"] "'volumes' and 'storage' cannot be combined";
  List.iter (fun (i, n) ->
    e "E012" ["storage"; string_of_int i; "name"] (Printf.sprintf "duplicate storage name '%s'" n))
    (duplicates (List.map (fun v -> v.st_name) svc.storage));
  List.iteri (fun i v ->
    let p = ["storage"; string_of_int i] in
    if String.length v.mount = 0 || v.mount.[0] <> '/' then
      e "E031" (p @ ["mount"]) (Printf.sprintf "mount '%s' is not an absolute path" v.mount);
    if v.st_class <> "ephemeral" then begin
      match v.size with
      | None -> e "E032" (p @ ["size"]) "size is required for a persistent volume"
      | Some s -> if quantity_value ~cpu:false s = None then
          e "E015" (p @ ["size"]) (Printf.sprintf "invalid quantity '%s' (Ki, Mi, Gi or Ti)" s)
    end;
    if v.st_class = "local" && v.rebuild = None && svc.backup = None then
      e "E033" p
        (Printf.sprintf "local volume '%s' has neither 'backup' nor 'rebuild': decide what \
                         happens to its data when the node is lost" v.st_name)) svc.storage;
  (* Secrets *)
  List.iter (fun (i, n) ->
    e "E012" ["secrets"; string_of_int i; "name"] (Printf.sprintf "duplicate secret name '%s'" n))
    (duplicates (List.map (fun s -> s.sec_name) svc.secrets));
  List.iteri (fun i s ->
    match s.sec_ref, s.generate with
    | None, None | Some _, Some _ ->
      e "E034" ["secrets"; string_of_int i]
        (Printf.sprintf "secret '%s': exactly one of 'ref' and 'generate'" s.sec_name)
    | Some r, None when not (String.contains r ':') ->
      e "E007" ["secrets"; string_of_int i; "ref"]
        (Printf.sprintf "secret reference '%s' (expected <backend>:<path>[#<key>])" r)
    | _ -> ()) svc.secrets;
  let declared = List.map (fun s -> s.sec_name) svc.secrets in
  let check_templates where kv =
    List.iter (fun (k, v) ->
      List.iter (fun name ->
        if not (List.mem name declared) then
          e "E020" (where @ [k]) (Printf.sprintf "{secret.%s} refers to no declared secret" name))
        (template_secrets v)) kv in
  check_templates ["environment"] svc.environment;
  List.iteri (fun i (c : consumption) ->
    check_templates ["consumes"; string_of_int i; "inject"] c.inject) svc.consumes;
  List.iter (fun (k, v) ->
    if secret_like_key (String.uppercase_ascii k) && v <> ""
       && not (String.contains v '{') then
      e "W012" ["environment"; k] "looks like a literal secret: declare it in 'secrets'")
    svc.environment;
  (* Exposure *)
  List.iteri (fun i x ->
    if not (List.exists (fun (p : port) -> p.container = x.exp_port) svc.ports) then
      e "E035" ["exposure"; string_of_int i; "port"]
        (Printf.sprintf "port %d is not declared in 'ports'" x.exp_port)) svc.exposure;
  (* Route labels *)
  (match svc.security with
   | None -> ()
   | Some sec ->
     List.iteri (fun i (r : route_label) ->
       if r.public && (r.classification <> None || r.categories <> [] || r.required_clearance <> []) then
         e "E043" ["security"; "route_labels"; string_of_int i]
           (Printf.sprintf "route '%s' is public: it cannot also require a classification, \
                            categories or roles" r.route)) sec.route_labels)

let check_pattern cx (p : pattern_manifest) =
  let e = note cx in
  List.iter (fun (i, n) ->
    e "E051" ["zones"; string_of_int i; "name"] (Printf.sprintf "zone '%s' is defined twice" n))
    (duplicates (List.map (fun z -> z.zname) p.zones));
  List.iter (fun (i, n) ->
    e "E012" ["constraints"; string_of_int i; "id"] (Printf.sprintf "duplicate constraint id '%s'" n))
    (duplicates (List.map (fun c -> c.cid) p.constraints));
  (match p.lattice with
   | None -> ()
   | Some l ->
     List.iteri (fun i z ->
       let zp = ["zones"; string_of_int i] in
       if not (List.mem z.zlevel l.levels) then
         e "E042" (zp @ ["level"]) (Printf.sprintf "level '%s' is not in the lattice (%s)"
                                      z.zlevel (String.concat " < " l.levels));
       List.iter (fun c ->
         if not (List.mem c l.lat_categories) then
           e "E042" (zp @ ["categories"]) (Printf.sprintf "category '%s' is not in the lattice" c))
         z.zcategories) p.zones);
  List.iter (fun (z, _) ->
    if p.zones <> [] && not (List.exists (fun d -> d.zname = z) p.zones) then
      e "E042" ["assurance"; z] (Printf.sprintf "zone '%s' is not defined by this pattern" z))
    p.pat_assurance

let check_infrastructure cx (i : infrastructure_manifest) =
  match i.proposed_topology with
  | None -> ()
  | Some t ->
    List.iteri (fun k (r : firewall_rule) ->
      if r.action = Allow && r.flow = None then
        note cx "E045" ["proposed_topology"; "network"; "firewall"; string_of_int k]
          (Printf.sprintf "'%s' opens a path without the declared flow that justifies it \
                           (expected: (consumer -> service))" (firewall_rule_to_string r)))
      t.firewall

let check_profile cx (pp : provisioning_profile_manifest) =
  if not (is_sha256 pp.pp_os.os_sha256) then
    note cx "E011" ["os"; "sha256"] "expected 64 hexadecimal characters (SHA-256)";
  if pp.pp_bundles = [] && pp.pp_cloud_init_extra = None then
    note cx "W002" ["bundles"]
      "no bundles and no cloud_init_extra: nothing will happen at provision time";
  List.iter (fun (i, n) ->
    note cx "E012" ["bundles"; string_of_int i; "name"] (Printf.sprintf "bundle '%s' listed twice" n))
    (duplicates (List.map (fun b -> b.bundle_name) pp.pp_bundles))

(** Stage-1 checks of a complete manifest. *)
let check cx = function
  | MService s -> check_service cx s
  | MPattern p -> check_pattern cx p
  | MInfrastructure i -> check_infrastructure cx i
  | MProvisioningProfile p -> check_profile cx p
  | MStack s -> if s.services = [] then note cx "W002" ["services"] "the stack has no services"
  | MBundle _ -> ()

(* ============================================================ *)
(* File loading                                                  *)
(* ============================================================ *)

(** Parse and check a manifest file. The manifest is returned when it could
    be parsed, even if checks found errors; the diagnostics are sorted,
    errors first. *)
let diagnose_file (path : Fpath.t) : manifest option * Diagnostic.t list =
  match Bos.OS.File.read path with
  | Error (`Msg msg) -> (None, [Diagnostic.make "E001" [] ("cannot read file: " ^ msg)])
  | Ok content ->
    match Yaml.of_string content with
    | Error (`Msg msg) -> (None, [Diagnostic.make "E001" [] ("invalid YAML: " ^ msg)])
    | Ok yaml ->
      match parse_manifest_cx yaml with
      | Error d -> (None, [d])
      | Ok (m, cx) ->
        check cx m;
        (Some m, Diagnostic.sort (List.rev cx.diags))

(** For commands that consume manifests: the manifest and its warnings, or
    the errors that make it unusable. *)
let load_file (path : Fpath.t) : (manifest * string list, string) Stdlib.result =
  let file = Fpath.to_string path in
  match diagnose_file path with
  | m, diags ->
    let errors = List.filter Diagnostic.is_error diags in
    match m, errors with
    | Some m, [] -> Ok (m, List.map Diagnostic.to_string diags)
    | _, ds ->
      Error (String.concat "\n" (List.map (fun d -> file ^ ": " ^ Diagnostic.to_string d) ds))

(** Back-compatible accessor: warnings of a manifest. *)
let validate (m : manifest) : string list =
  let cx = { minor = supported_minor; diags = [] } in
  check cx m;
  List.map Diagnostic.to_string (List.rev cx.diags)
