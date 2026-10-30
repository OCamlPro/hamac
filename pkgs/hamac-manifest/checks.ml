(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Checks of a manifest on its own (stage 1) that the vocabulary of Hamac
    does not express: they read strings (digests, paths, references of
    secrets) or compare quantities with their units. The vocabulary checks
    the rest ({!Loaf_source}).

    Each finding carries the path of the value in {!Types} it is about
    (["resources"; "memory_request"], ["storage"; "0"; "mount"]), which
    {!Loaf_source} turns into the location of the LOAF fact. *)

open Types

let is_digit c = c >= '0' && c <= '9'

let is_sha256 s =
  String.length s = 64
  && String.for_all (fun c -> is_digit c || (c >= 'a' && c <= 'f')) (String.lowercase_ascii s)

(** Bytes of a memory quantity ([512Mi], [1Gi]), or millicores of a CPU
    quantity ([2], [500m]). [None] if malformed. *)
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

let check_service e (svc : service_manifest) =
  (match svc.artifact with
   | Some a ->
     if not (is_sha256 a.sha256) then
       e "E011" ["artifact"; "sha256"]
         (Printf.sprintf "sha256 of the artifact of %s: expected 64 hexadecimal characters" svc.name);
     if a.format = "oci-image" && not (String.contains a.path '@') then
       e "W010" ["artifact"; "path"]
         (Printf.sprintf "OCI image '%s' of %s is not pinned by digest (@sha256:…)" a.path svc.name)
   | None -> ());
  (match svc.resources with
   | None -> ()
   | Some r ->
     let q ~cpu v = Option.bind v (quantity_value ~cpu) in
     (match q ~cpu:false r.memory_request, q ~cpu:false r.memory_limit with
      | Some a, Some b when a > b ->
        e "E014" ["resources"; "memory_request"]
          (Printf.sprintf "memory_request of %s above its memory_limit" svc.name)
      | _ -> ());
     (match q ~cpu:true r.cpu_request, q ~cpu:true r.cpu_limit with
      | Some a, Some b when a > b ->
        e "E014" ["resources"; "cpu_request"]
          (Printf.sprintf "cpu_request of %s above its cpu_limit" svc.name)
      | _ -> ()));
  (match svc.health_check with
   | Some h when h.timeout >= h.interval ->
     e "W011" ["health_check"; "timeout"]
       (Printf.sprintf "health check of %s: timeout is not shorter than interval" svc.name)
   | _ -> ());
  List.iteri (fun i v ->
    let p = ["storage"; string_of_int i] in
    if String.length v.mount = 0 || v.mount.[0] <> '/' then
      e "E031" (p @ ["mount"])
        (Printf.sprintf "mount '%s' of volume %s is not an absolute path" v.mount v.st_name);
    if v.st_class = "local" && v.rebuild = None && svc.backup = None then
      e "E033" p
        (Printf.sprintf "local volume '%s' has neither 'backup' nor 'rebuild': decide what \
                         happens to its data when the node is lost" v.st_name)) svc.storage;
  List.iteri (fun i s ->
    match s.sec_ref with
    | Some r when not (String.contains r ':') ->
      e "E007" ["secrets"; string_of_int i; "ref"]
        (Printf.sprintf "reference '%s' of secret %s: expected <backend>:<path>[#<key>]" r s.sec_name)
    | _ -> ()) svc.secrets;
  (* The vocabulary checks the secrets of the environment; those of an
     inject come from a template filled by the model. *)
  let declared = List.map (fun s -> s.sec_name) svc.secrets in
  List.iteri (fun i (c : consumption) ->
    List.iter (fun (k, v) ->
      List.iter (fun name ->
        if not (List.mem name declared) then
          e "E020" ["consumes"; string_of_int i; "inject"; k]
            (Printf.sprintf "inject %s of consumes %s: {secret.%s} refers to no declared secret"
               k c.name name))
        (template_secrets v)) c.inject) svc.consumes;
  List.iter (fun (k, v) ->
    if secret_like_key (String.uppercase_ascii k) && v <> ""
       && not (String.contains v '{') then
      e "W012" ["environment"; k]
        (Printf.sprintf "environment %s of %s looks like a literal secret: declare it as a secret"
           k svc.name))
    svc.environment

let check_pattern e (p : pattern_manifest) =
  List.iter (fun (z, _) ->
    if p.zones <> [] && not (List.exists (fun d -> d.zname = z) p.zones) then
      e "E042" ["assurance"; z]
        (Printf.sprintf "assurance of zone '%s': the zone is not defined by %s" z p.pat_name))
    p.pat_assurance

let check_profile e (pp : provisioning_profile_manifest) =
  if not (is_sha256 pp.pp_os.os_sha256) then
    e "E011" ["os"; "sha256"]
      (Printf.sprintf "sha256 of the os of %s: expected 64 hexadecimal characters" pp.pp_name);
  if pp.pp_bundles = [] && pp.pp_cloud_init_extra = None then
    e "W013" ["bundles"]
      "no bundles and no cloud_init_extra: nothing will happen at provision time";
  List.iter (fun (i, n) ->
    e "E012" ["bundles"; string_of_int i] (Printf.sprintf "bundle '%s' listed twice" n))
    (duplicates (List.map (fun b -> b.bundle_name) pp.pp_bundles))

(** The findings of the checks of a manifest, in the order of discovery. *)
let check (m : manifest) : Diagnostic.t list =
  let found = ref [] in
  let e code path message = found := Diagnostic.make code path message :: !found in
  (match m with
   | MService s -> check_service e s
   | MPattern p -> check_pattern e p
   | MProvisioningProfile p -> check_profile e p
   | MStack s -> if s.services = [] then e "W002" ["services"] "the stack has no services"
   | MInfrastructure _ | MBundle _ -> ());
  List.rev !found
