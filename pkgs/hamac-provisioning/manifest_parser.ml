(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** YAML manifest parser for hamac.

    Parses .sieste.yml files into structured [Manifest_types.manifest] values
    with validation and clear error reporting. *)

open Manifest_types

(* ============================================================ *)
(* Parse errors                                                  *)
(* ============================================================ *)

type parse_error = {
  path: string list;    (** YAML path, e.g. ["services"; "0"; "artifact"] *)
  message: string;
}

let pp_error fmt e =
  let path = match e.path with
    | [] -> "(root)"
    | p -> String.concat "." p
  in
  Format.fprintf fmt "%s: %s" path e.message

let error path message = Error { path; message }

(* ============================================================ *)
(* YAML extraction helpers                                       *)
(* ============================================================ *)

type 'a result = ('a, parse_error) Stdlib.result

let field_opt (name : string) (fields : (string * Yaml.value) list) : Yaml.value option =
  List.assoc_opt name fields

let require (path : string list) (name : string) (fields : (string * Yaml.value) list) : Yaml.value result =
  match List.assoc_opt name fields with
  | Some v -> Ok v
  | None -> error (path @ [name]) (Printf.sprintf "required field '%s' is missing" name)

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

(** Extract a string field, required *)
let req_string path name fields =
  match require path name fields with
  | Error e -> Error e
  | Ok v -> as_string (path @ [name]) v

(** Extract a string field, optional *)
let opt_string name fields =
  match field_opt name fields with
  | None | Some `Null -> Ok None
  | Some v ->
    match as_string [] v with
    | Ok s -> Ok (Some s)
    | Error _ -> Ok None

(** Extract an int field, optional *)
let opt_int name fields =
  match field_opt name fields with
  | None | Some `Null -> Ok None
  | Some v ->
    match as_int [] v with
    | Ok i -> Ok (Some i)
    | Error e -> Error e

(** Extract an int field with default *)
let int_or path name fields ~default =
  match field_opt name fields with
  | None | Some `Null -> Ok default
  | Some v -> as_int (path @ [name]) v

(** Extract a string→string map from a YAML object *)
let string_map path (v : Yaml.value) : (string * string) list result =
  match v with
  | `O fields ->
    let rec aux = function
      | [] -> Ok []
      | (k, v) :: rest ->
        match as_string (path @ [k]) v with
        | Error e -> Error e
        | Ok s ->
          match aux rest with
          | Error e -> Error e
          | Ok tl -> Ok ((k, s) :: tl)
    in
    aux fields
  | `Null -> Ok []
  | _ -> error path "expected a key-value map"

(* Monadic let for result *)
let ( let* ) = Stdlib.Result.bind

(* ============================================================ *)
(* Parse artifact                                                *)
(* ============================================================ *)

let parse_artifact path (v : Yaml.value) : artifact result =
  let* fields = as_obj path v in
  let* path_val = req_string path "path" fields in
  let* sha256 = req_string path "sha256" fields in
  let* format = req_string path "format" fields in
  Ok { path = path_val; sha256; format }

(* ============================================================ *)
(* Parse port                                                    *)
(* ============================================================ *)

let parse_port path (v : Yaml.value) : port result =
  let* fields = as_obj path v in
  let* host = (let* v = require path "host" fields in as_int (path @ ["host"]) v) in
  let* container = (let* v = require path "container" fields in as_int (path @ ["container"]) v) in
  let* protocol = match opt_string "protocol" fields with
    | Ok (Some p) -> Ok p
    | Ok None -> Ok "tcp"
    | Error e -> Error e
  in
  Ok { host; container; protocol }

(* ============================================================ *)
(* Parse volume                                                  *)
(* ============================================================ *)

let parse_volume path (v : Yaml.value) : volume result =
  let* fields = as_obj path v in
  let* host_path = req_string path "host" fields in
  let* container_path = req_string path "container" fields in
  let* read_only = match field_opt "read_only" fields with
    | None | Some `Null -> Ok false
    | Some v -> as_bool (path @ ["read_only"]) v
  in
  Ok { host_path; container_path; read_only }

(* ============================================================ *)
(* Parse consumption                                             *)
(* ============================================================ *)

let parse_consumption path (v : Yaml.value) : consumption result =
  let* fields = as_obj path v in
  let* name = req_string path "name" fields in
  let* capability = opt_string "capability" fields in
  let* service = opt_string "service" fields in
  let* inject = match field_opt "inject" fields with
    | None | Some `Null -> Ok []
    | Some v -> string_map (path @ ["inject"]) v
  in
  Ok { name; capability; service; inject }

(* ============================================================ *)
(* Parse route_label                                             *)
(* ============================================================ *)

let parse_route_label path (v : Yaml.value) : route_label result =
  let* fields = as_obj path v in
  let* route = req_string path "route" fields in
  let* clearance_list = (let* v = require path "required_clearance" fields in
    as_list (path @ ["required_clearance"]) v) in
  let rec parse_strings acc = function
    | [] -> Ok (List.rev acc)
    | x :: rest ->
      let* s = as_string path x in
      parse_strings (s :: acc) rest
  in
  let* required_clearance = parse_strings [] clearance_list in
  Ok { route; required_clearance }

(* ============================================================ *)
(* Parse security                                                *)
(* ============================================================ *)

let parse_security path (v : Yaml.value) : security result =
  let* fields = as_obj path v in
  let* zone = req_string path "zone" fields in
  let* route_labels = match field_opt "route_labels" fields with
    | None | Some `Null -> Ok []
    | Some v ->
      let* items = as_list (path @ ["route_labels"]) v in
      let rec aux i = function
        | [] -> Ok []
        | x :: rest ->
          let* rl = parse_route_label (path @ ["route_labels"; string_of_int i]) x in
          let* tl = aux (i + 1) rest in
          Ok (rl :: tl)
      in
      aux 0 items
  in
  Ok { zone; route_labels }

(* ============================================================ *)
(* Parse resources                                               *)
(* ============================================================ *)

let parse_resources path (v : Yaml.value) : resources result =
  let* fields = as_obj path v in
  let* memory_limit = opt_string "memory_limit" fields in
  let* memory_request = opt_string "memory_request" fields in
  let* cpu_limit = opt_string "cpu_limit" fields in
  let* cpu_request = opt_string "cpu_request" fields in
  Ok { memory_limit; memory_request; cpu_limit; cpu_request }

(* ============================================================ *)
(* Parse autoscaling                                             *)
(* ============================================================ *)

let parse_autoscaling path (v : Yaml.value) : autoscaling result =
  let* fields = as_obj path v in
  let* min_replicas = (let* v = require path "min_replicas" fields in
    as_int (path @ ["min_replicas"]) v) in
  let* max_replicas = (let* v = require path "max_replicas" fields in
    as_int (path @ ["max_replicas"]) v) in
  let* cpu_threshold = opt_int "cpu_threshold" fields in
  let* memory_threshold = opt_int "memory_threshold" fields in
  Ok { min_replicas; max_replicas; cpu_threshold; memory_threshold }

(* ============================================================ *)
(* Parse health_check                                            *)
(* ============================================================ *)

let parse_health_check path (v : Yaml.value) : health_check result =
  let* fields = as_obj path v in
  let* hc_path = req_string path "path" fields in
  let* interval = int_or path "interval" fields ~default:30 in
  let* timeout = int_or path "timeout" fields ~default:5 in
  let* retries = int_or path "retries" fields ~default:3 in
  Ok { path = hc_path; interval; timeout; retries }

(* ============================================================ *)
(* Parse metrics                                                 *)
(* ============================================================ *)

let parse_metrics path (v : Yaml.value) : metrics result =
  let* fields = as_obj path v in
  let* provider = req_string path "provider" fields in
  let* m_path = req_string path "path" fields in
  let* port = opt_int "port" fields in
  Ok { provider; path = m_path; port }

(* ============================================================ *)
(* Parse logging                                                 *)
(* ============================================================ *)

let parse_logging path (v : Yaml.value) : logging result =
  let* fields = as_obj path v in
  let* fmt = match opt_string "format" fields with
    | Ok (Some f) -> Ok f
    | Ok None -> Ok "text"
    | Error e -> Error e
  in
  let* level = match opt_string "level" fields with
    | Ok (Some l) -> Ok l
    | Ok None -> Ok "info"
    | Error e -> Error e
  in
  Ok { format = fmt; level }

(* ============================================================ *)
(* Parse optional sub-object                                     *)
(* ============================================================ *)

let parse_opt name fields path parse_fn =
  match field_opt name fields with
  | None | Some `Null -> Ok None
  | Some v ->
    let* x = parse_fn (path @ [name]) v in
    Ok (Some x)

(* ============================================================ *)
(* Parse list of items                                           *)
(* ============================================================ *)

let parse_list name fields path parse_fn =
  match field_opt name fields with
  | None | Some `Null -> Ok []
  | Some v ->
    let* items = as_list (path @ [name]) v in
    let rec aux i = function
      | [] -> Ok []
      | x :: rest ->
        let* item = parse_fn (path @ [name; string_of_int i]) x in
        let* tl = aux (i + 1) rest in
        Ok (item :: tl)
    in
    aux 0 items

(* ============================================================ *)
(* Parse service manifest                                        *)
(* ============================================================ *)

let parse_readiness path (v : Yaml.value) : readiness result =
  let* fields = as_obj path v in
  let* command = (let* v = require path "command" fields in
    let* items = as_list (path @ ["command"]) v in
    let rec aux = function
      | [] -> Ok []
      | x :: rest ->
        let* s = as_string (path @ ["command"]) x in
        let* tl = aux rest in
        Ok (s :: tl)
    in
    aux items)
  in
  let* readiness_interval = int_or path "interval" fields ~default:5 in
  let* readiness_timeout = int_or path "timeout" fields ~default:30 in
  Ok { command; readiness_interval; readiness_timeout }

let parse_service_manifest path (fields : (string * Yaml.value) list) : service_manifest result =
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = req_string path "name" fields in
  let* runtime = req_string path "runtime" fields in
  let* artifact = parse_opt "artifact" fields path parse_artifact in
  let* capability = opt_string "capability" fields in
  let* inputs = match field_opt "inputs" fields with
    | None | Some `Null -> Ok []
    | Some v -> string_map (path @ ["inputs"]) v
  in
  let* consumes = parse_list "consumes" fields path parse_consumption in
  let* provides = match field_opt "provides" fields with
    | None | Some `Null -> Ok []
    | Some v -> string_map (path @ ["provides"]) v
  in
  let* readiness = parse_opt "readiness" fields path parse_readiness in
  let* security = parse_opt "security" fields path parse_security in
  let* ports = parse_list "ports" fields path parse_port in
  let* volumes = parse_list "volumes" fields path parse_volume in
  let* environment = match field_opt "environment" fields with
    | None | Some `Null -> Ok []
    | Some v -> string_map (path @ ["environment"]) v
  in
  let* resources = parse_opt "resources" fields path parse_resources in
  let* replicas = int_or path "replicas" fields ~default:1 in
  let* autoscaling = parse_opt "autoscaling" fields path parse_autoscaling in
  let* health_check = parse_opt "health_check" fields path parse_health_check in
  let* metrics = parse_opt "metrics" fields path parse_metrics in
  let* logging = parse_opt "logging" fields path parse_logging in
  Ok {
    manifest_version; name; runtime; artifact; capability; inputs;
    consumes; provides; readiness; security; ports; volumes;
    environment; resources; replicas; autoscaling;
    health_check; metrics; logging;
  }

(* ============================================================ *)
(* Parse stack manifest                                          *)
(* ============================================================ *)

let parse_stack_consume_override path (v : Yaml.value) : stack_consume_override result =
  let* fields = as_obj path v in
  let* consume_name = req_string path "name" fields in
  let* provider = req_string path "provider" fields in
  Ok { consume_name; provider }

let parse_stack_service_ref path (v : Yaml.value) : stack_service_ref result =
  let* fields = as_obj path v in
  let* ref_path = req_string path "ref" fields in
  let* replicas_override = opt_int "replicas" fields in
  let* consumes_override = parse_list "consumes" fields path parse_stack_consume_override in
  Ok { ref_path; replicas_override; consumes_override }

let parse_stack_manifest path (fields : (string * Yaml.value) list) : stack_manifest result =
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = req_string path "name" fields in
  let* services = parse_list "services" fields path parse_stack_service_ref in
  let* infrastructure = opt_string "infrastructure" fields in
  Ok { manifest_version; name; services; infrastructure }

(* ============================================================ *)
(* Parse infrastructure manifest                                 *)
(* ============================================================ *)

let parse_infra_node path (v : Yaml.value) : infra_node result =
  let* fields = as_obj path v in
  let* role = req_string path "role" fields in
  let* count = int_or path "count" fields ~default:1 in
  let* ram = opt_string "ram" fields in
  let* cpu = opt_int "cpu" fields in
  let* boot = opt_string "boot" fields in
  let* os_image = (match field_opt "os" fields with
    | None | Some `Null -> Ok None
    | Some v ->
      let* os_fields = as_obj (path @ ["os"]) v in
      opt_string "image" os_fields)
  in
  let* os_sha256 = (match field_opt "os" fields with
    | None | Some `Null -> Ok None
    | Some v ->
      let* os_fields = as_obj (path @ ["os"]) v in
      opt_string "sha256" os_fields)
  in
  let* isolated = match field_opt "isolated" fields with
    | None | Some `Null -> Ok false
    | Some v -> as_bool (path @ ["isolated"]) v
  in
  let* provisioning_profile = opt_string "provisioning_profile" fields in
  Ok { role; count; ram; cpu; boot; os_image; os_sha256; isolated; provisioning_profile }

let parse_network_segment path (v : Yaml.value) : network_segment result =
  let* fields = as_obj path v in
  let* seg_name = req_string path "name" fields in
  let* cidr = req_string path "cidr" fields in
  let* vlan = opt_int "vlan" fields in
  Ok { seg_name; cidr; vlan }

let parse_firewall_rule path (v : Yaml.value) : firewall_rule result =
  let* rule = as_string path v in
  Ok { rule }

let parse_infra_topology path (v : Yaml.value) : infra_topology result =
  let* fields = as_obj path v in
  let* nodes = parse_list "nodes" fields path parse_infra_node in
  let* segments = match field_opt "network" fields with
    | None | Some `Null -> Ok []
    | Some v ->
      let* net_fields = as_obj (path @ ["network"]) v in
      parse_list "segments" net_fields (path @ ["network"]) parse_network_segment
  in
  let* firewall = match field_opt "network" fields with
    | None | Some `Null -> Ok []
    | Some v ->
      let* net_fields = as_obj (path @ ["network"]) v in
      parse_list "firewall" net_fields (path @ ["network"]) parse_firewall_rule
  in
  Ok { nodes; segments; firewall }

let parse_infra_requirements path (v : Yaml.value) : infra_requirements result =
  let* fields = as_obj path v in
  let* min_nodes = opt_int "nodes" fields in
  let* total_ram = opt_string "total_ram" fields in
  let* total_cpu = opt_int "total_cpu" fields in
  Ok { min_nodes; total_ram; total_cpu }

let parse_infrastructure_manifest path (fields : (string * Yaml.value) list) : infrastructure_manifest result =
  let* manifest_version = req_string path "manifest_version" fields in
  let* name = req_string path "name" fields in
  let* backend = req_string path "backend" fields in
  let* minimum_requirements = parse_opt "minimum_requirements" fields path parse_infra_requirements in
  let* proposed_topology = parse_opt "proposed_topology" fields path parse_infra_topology in
  let* warnings = match field_opt "warnings" fields with
    | None | Some `Null -> Ok []
    | Some v ->
      let* items = as_list (path @ ["warnings"]) v in
      let rec aux = function
        | [] -> Ok []
        | x :: rest ->
          let* s = as_string (path @ ["warnings"]) x in
          let* tl = aux rest in
          Ok (s :: tl)
      in
      aux items
  in
  Ok { manifest_version; name; backend; minimum_requirements; proposed_topology; warnings }

(* ============================================================ *)
(* Parse provisioning_profile manifest                           *)
(* ============================================================ *)

let parse_os_image_spec path (v : Yaml.value) : os_image_spec result =
  let* fields = as_obj path v in
  let* os_image_name = req_string path "image" fields in
  let* os_url = req_string path "url" fields in
  let* os_sha256 = req_string path "sha256" fields in
  let* os_format = req_string path "format" fields in
  let* os_family = match opt_string "family" fields with
    | Ok (Some f) -> Ok f
    | Ok None -> Ok "debian"   (* défaut : famille apt (debian/ubuntu) *)
    | Error e -> Error e
  in
  (* Assets dérivés pour install physique (bmaptool) — optionnels, vides si
     absents. Le qcow2 ci-dessus reste la référence. *)
  let* os_raw_zst_url = match opt_string "raw_zst_url" fields with
    | Ok v -> Ok (Option.value v ~default:"")
    | Error e -> Error e
  in
  let* os_raw_zst_sha256 = match opt_string "raw_zst_sha256" fields with
    | Ok v -> Ok (Option.value v ~default:"")
    | Error e -> Error e
  in
  let* os_bmap_url = match opt_string "bmap_url" fields with
    | Ok v -> Ok (Option.value v ~default:"")
    | Error e -> Error e
  in
  Ok { os_image_name; os_url; os_sha256; os_format; os_family;
       os_raw_zst_url; os_raw_zst_sha256; os_bmap_url }

(** Parse un bundle_ref : name + params (params bruts, transmis tels quels
    au générateur Jinja2). *)
let parse_bundle_ref path (v : Yaml.value) : bundle_ref result =
  let* fields = as_obj path v in
  let* bundle_name = req_string path "name" fields in
  let bundle_params = match field_opt "params" fields with
    | None | Some `Null -> []
    | Some (`O kv) -> kv
    | Some _ -> []  (* Tolérant : type non-objet => params vides *)
  in
  Ok { bundle_name; bundle_params }

let parse_provisioning_profile_manifest path (fields : (string * Yaml.value) list)
    : provisioning_profile_manifest result =
  let* pp_manifest_version = req_string path "manifest_version" fields in
  let* pp_name = req_string path "name" fields in
  let* pp_os = (let* v = require path "os" fields in
                parse_os_image_spec (path @ ["os"]) v) in
  let* pp_bundles = parse_list "bundles" fields path parse_bundle_ref in
  let pp_cloud_init_extra = field_opt "cloud_init_extra" fields in
  Ok { pp_manifest_version; pp_name; pp_os; pp_bundles; pp_cloud_init_extra }

(* ============================================================ *)
(* Parse bundle manifest                                         *)
(* ============================================================ *)

let parse_bundle_param_spec path ((name, v) : string * Yaml.value)
    : bundle_param_spec result =
  let* fields = as_obj (path @ [name]) v in
  let* param_type = req_string (path @ [name]) "type" fields in
  let* param_required = match field_opt "required" fields with
    | None | Some `Null -> Ok false
    | Some v -> as_bool (path @ [name; "required"]) v
  in
  Ok { param_name = name; param_type; param_required }

let parse_bundle_manifest path (fields : (string * Yaml.value) list)
    : bundle_manifest result =
  let* bdl_manifest_version = req_string path "manifest_version" fields in
  let* bdl_name = req_string path "name" fields in
  let* bdl_version = match opt_string "version" fields with
    | Ok (Some v) -> Ok v
    | Ok None -> Ok "0.1.0"
    | Error e -> Error e
  in
  let* bdl_description = match opt_string "description" fields with
    | Ok (Some v) -> Ok v
    | Ok None -> Ok ""
    | Error e -> Error e
  in
  let* bdl_params = match field_opt "params" fields with
    | None | Some `Null -> Ok []
    | Some (`O kv) ->
      let rec aux = function
        | [] -> Ok []
        | entry :: rest ->
          let* spec = parse_bundle_param_spec (path @ ["params"]) entry in
          let* tl = aux rest in
          Ok (spec :: tl)
      in
      aux kv
    | Some _ -> error (path @ ["params"]) "expected an object mapping name → spec"
  in
  let parse_string_list field_name =
    match field_opt field_name fields with
    | None | Some `Null -> Ok []
    | Some v ->
      let* items = as_list (path @ [field_name]) v in
      let rec aux i = function
        | [] -> Ok []
        | x :: rest ->
          let* s = as_string (path @ [field_name; string_of_int i]) x in
          let* tl = aux (i + 1) rest in
          Ok (s :: tl)
      in
      aux 0 items
  in
  let* bdl_depends_on = parse_string_list "depends_on" in
  Ok { bdl_manifest_version; bdl_name; bdl_version; bdl_description;
       bdl_params; bdl_depends_on }

(* ============================================================ *)
(* Top-level parser                                              *)
(* ============================================================ *)

let parse_manifest (yaml : Yaml.value) : manifest result =
  let path = [] in
  let* fields = as_obj path yaml in
  let kind = match field_opt "kind" fields with
    | Some (`String s) -> Some s
    | _ -> None
  in
  match kind with
  | Some "service" | None ->
    (* Default to service if no kind specified *)
    let* m = parse_service_manifest path fields in
    Ok (MService m)
  | Some "stack" ->
    let* m = parse_stack_manifest path fields in
    Ok (MStack m)
  | Some "infrastructure" ->
    let* m = parse_infrastructure_manifest path fields in
    Ok (MInfrastructure m)
  | Some "provisioning_profile" ->
    let* m = parse_provisioning_profile_manifest path fields in
    Ok (MProvisioningProfile m)
  | Some "bundle" ->
    let* m = parse_bundle_manifest path fields in
    Ok (MBundle m)
  | Some other ->
    error ["kind"] (Printf.sprintf "unknown manifest kind '%s' (expected: service, stack, infrastructure, provisioning_profile, bundle)" other)

(* ============================================================ *)
(* Validation                                                    *)
(* ============================================================ *)

(** Validate a parsed manifest for semantic coherence.
    Returns a list of warnings/errors. *)
let validate (m : manifest) : string list =
  let warnings = ref [] in
  let warn msg = warnings := msg :: !warnings in
  begin match m with
  | MService svc ->
    (* Check artifact hash length *)
    (match svc.artifact with
     | Some a when String.length a.sha256 < 64 ->
       warn (Printf.sprintf "artifact.sha256 looks too short (%d chars, expected 64 for SHA-256)" (String.length a.sha256))
     | _ -> ());
    (* Check consumes have capability or service *)
    List.iter (fun (c : consumption) ->
      if c.capability = None && c.service = None then
        warn (Printf.sprintf "consumes '%s': should have either 'capability' or 'service'" c.name)
    ) svc.consumes;
    (* Check replicas *)
    if svc.replicas < 1 then
      warn "replicas must be >= 1";
    (* Check autoscaling coherence *)
    (match svc.autoscaling with
     | Some a when a.min_replicas > a.max_replicas ->
       warn "autoscaling: min_replicas > max_replicas"
     | _ -> ());
  | MStack stk ->
    if stk.services = [] then
      warn "stack has no services";
  | MInfrastructure _ -> ()
  | MProvisioningProfile pp ->
    if String.length pp.pp_os.os_sha256 < 64 then
      warn (Printf.sprintf "os.sha256 looks too short (%d chars, expected 64)"
              (String.length pp.pp_os.os_sha256));
    if pp.pp_bundles = [] && pp.pp_cloud_init_extra = None then
      warn "provisioning_profile has no bundles and no cloud_init_extra: nothing will happen at provision time";
    (* MAC formats des params (sanity check minimal : pas de doublon de bundles) *)
    let names = List.map (fun b -> b.bundle_name) pp.pp_bundles in
    let unique = List.sort_uniq compare names in
    if List.length names <> List.length unique then
      warn "bundle list contains duplicates";
  | MBundle b ->
    if b.bdl_name = "" then warn "bundle has empty name";
    (* Validation des types de params : on tolère un set fini *)
    List.iter (fun p ->
      let known = ["string"; "int"; "bool"; "list[string]"; "list[int]"; "object"] in
      if not (List.mem p.param_type known) then
        warn (Printf.sprintf "param '%s': unknown type '%s' (known: %s)"
                p.param_name p.param_type (String.concat ", " known))
    ) b.bdl_params
  end;
  List.rev !warnings

(* ============================================================ *)
(* File loading                                                  *)
(* ============================================================ *)

let load_file (path : Fpath.t) : (manifest * string list, string) Stdlib.result =
  match Bos.OS.File.read path with
  | Error (`Msg msg) ->
    Error (Printf.sprintf "cannot read %s: %s" (Fpath.to_string path) msg)
  | Ok content ->
    match Yaml.of_string content with
    | Error (`Msg msg) ->
      Error (Printf.sprintf "invalid YAML in %s: %s" (Fpath.to_string path) msg)
    | Ok yaml ->
      match parse_manifest yaml with
      | Error e ->
        Error (Printf.sprintf "%s: %s" (Fpath.to_string path) (Format.asprintf "%a" pp_error e))
      | Ok m ->
        let warnings = validate m in
        Ok (m, warnings)
