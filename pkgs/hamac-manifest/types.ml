(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Manifest types for hamac.

    Structured OCaml types for the kinds of manifests that the vocabulary of
    Hamac declares (vocabulary/hamac.loaf), built by {!Loaf_source}. *)

(* ============================================================ *)
(* Common types                                                  *)
(* ============================================================ *)

(** The host name of a service, an instance or a node, derived from its
    name: a host name admits [-], not [_] (RFC 1123), and a LOAF name
    admits [_], not [-]. It is the only place where a name changes form:
    everything else shows names as the files write them. *)
let hostname name = String.map (fun ch -> if ch = '_' then '-' else ch) name

type artifact = {
  path: string;
  sha256: string;
  format: string;           (** native-linux-amd64 | oci-image | ... *)
} [@@deriving show]

type metadata = {
  description: string option;
  labels: (string * string) list;
  annotations: (string * string) list;
} [@@deriving show]

let no_metadata = { description = None; labels = []; annotations = [] }

type port = {
  container: int;
  protocol: string;         (** tcp | udp *)
} [@@deriving show]

(** Authorization of a route: the subject's level must be at least
    [classification], it must hold every category of [categories], and at
    least one role of [required_clearance] when that list is not empty. A
    [public] route requires no token. *)
type route_label = {
  route: string;
  methods: string list;           (** empty = every method *)
  public: bool;
  classification: string option;  (** a level of the lattice *)
  categories: string list;
  required_clearance: string list;
} [@@deriving show]

type security = {
  zone: string;              (** a zone of the stack's patterns *)
  route_labels: route_label list;
} [@@deriving show]

(* ---- Storage, secrets, placement, exposure (experimental in 1.1) ---- *)

type storage_volume = {
  st_name: string;
  mount: string;
  st_class: string;          (** ephemeral | local | replicated *)
  size: string option;
  rebuild: string option;    (** from-backup | from-object | from-replica | none *)
} [@@deriving show]

type backup_policy = {
  schedule: string option;
  retention: (string * int) list;
  pre: string list;
  post: string list;
  verify: string;            (** none | restore-test *)
} [@@deriving show]

type secret_generation = {
  gen_kind: string;          (** alpha | alnum *)
  gen_length: int;
} [@@deriving show]

type secret_decl = {
  sec_name: string;
  sec_ref: string option;    (** <backend>:<path>[#<key>] *)
  generate: secret_generation option;
  rotate: string option;
  sec_as: string;            (** env | file *)
} [@@deriving show]

(** Minimum per assurance axis; [None] imposes nothing on that axis. *)
type assurance = {
  boot: string option;       (** none < provider-vtpm < confidential-vm < measured-tpm2 *)
  operator: string option;   (** any < eu < secnumcloud < self *)
  physical: string option;   (** third-party < dedicated-rack < site *)
} [@@deriving show]

type placement = {
  needs: string list;
  pl_assurance: assurance option;
  spread: string;            (** none | host | failure_domain *)
  affinity: string list;
  anti_affinity: string list;
} [@@deriving show]

type exposure = {
  hostname: string;
  path_prefix: string;
  exp_port: int;
  exp_protocol: string;      (** http | tcp *)
  tls: string;               (** acme | internal | passthrough *)
} [@@deriving show]

type resources = {
  memory_limit: string option;
  memory_request: string option;
  cpu_limit: string option;
  cpu_request: string option;
} [@@deriving show]

type autoscaling = {
  min_replicas: int;
  max_replicas: int;
  cpu_threshold: int option;
  memory_threshold: int option;
} [@@deriving show]

type health_check = {
  path: string;
  interval: int;
  timeout: int;
  retries: int;
} [@@deriving show]

type metrics = {
  provider: string;
  path: string;
  port: int option;
} [@@deriving show]

type logging = {
  format: string;
  level: string;
} [@@deriving show]

type consumption = {
  name: string;
  capability: string option;  (** database, cache… *)
  service: string option;     (** reference to another service *)
  provider: string option;    (** the provider that the vocabulary retains *)
  inject: (string * string) list;
  mode: string;               (** request | push (push: experimental) *)
} [@@deriving show]

(* ============================================================ *)
(* kind: service                                                 *)
(* ============================================================ *)

type readiness = {
  command: string list;
  readiness_interval: int;
  readiness_timeout: int;
} [@@deriving show]

type service_manifest = {
  name: string;
  runtime: string;           (** http | cli | batch | eventloop | custom *)
  artifact: artifact option;
  capability: string option; (** for providers: database, cache, queue, storage *)
  inputs: (string * string) list;  (** for providers: input generation templates *)
  consumes: consumption list;
  provides: (string * string) list;
  readiness: readiness option;     (** for providers: readiness check *)
  security: security option;
  ports: port list;
  environment: (string * string) list;
  resources: resources option;
  replicas: int;
  autoscaling: autoscaling option;
  health_check: health_check option;
  metrics: metrics option;
  logging: logging option;
  metadata: metadata;
  storage: storage_volume list;
  backup: backup_policy option;
  secrets: secret_decl list;
  placement: placement option;
  exposure: exposure list;
} [@@deriving show]

(* ============================================================ *)
(* kind: pattern                                                 *)
(* ============================================================ *)

type lattice_decl = {
  levels: string list;       (** from the least to the most sensitive *)
  lat_categories: string list;
} [@@deriving show]

type zone_decl = {
  zname: string;
  zlevel: string;
  zcategories: string list;
  boundary: string;          (** firewall | diode *)
} [@@deriving show]

(** A constraint of a pattern: [violation] is an element of an aggregate
    of clingo, [terms : body], whose instances are the violations of the
    constraint, written on the predicates that the planner publishes
    (doc/typst/manifest.typ, section « Contraintes »). *)
type constraint_decl = {
  cid: string;
  cdescription: string;
  severity: string;          (** hard | soft *)
  weight: int;               (** of a soft constraint, default 1 *)
  cpriority: int;            (** of a soft constraint, default 1 *)
  violation: string;
  cloc: Diagnostic.loc option;  (** of the violation field *)
} [@@deriving show]

(** An objective of a pattern: [element] is an element of an aggregate of
    clingo, [weight, terms : body] (section « Objectifs »). *)
type objective = {
  direction: string;         (** minimize | maximize *)
  element: string;
  priority: int;             (** default 1 *)
  oloc: Diagnostic.loc option;
} [@@deriving show]

(** A pattern is the block of a LOAF module (module exemple_rh 1.0.0.),
    which a stack loads by use; a pattern that builds on another one uses
    its module. *)
type pattern_manifest = {
  pat_name: string;
  pat_version: string option;  (** version of its module, if it is one *)
  lattice: lattice_decl option;
  zones: zone_decl list;
  pat_assurance: (string * assurance) list;   (** zone name → minimum *)
  pat_roles: string list;    (** roles a route may require *)
  constraints: constraint_decl list;
  objectives: objective list;
} [@@deriving show]

(* ============================================================ *)
(* kind: stack                                                   *)
(* ============================================================ *)

type stack_service_ref = {
  ref_service: string;            (** name of the service *)
  replicas_override: int option;
  consumes_override: stack_consume_override list;
} [@@deriving show]

and stack_consume_override = {
  consume_name: string;
  provider: string;
} [@@deriving show]

type stack_manifest = {
  name: string;
  accept_experimental: bool;
  services: stack_service_ref list;
  infrastructure: string option;   (** name of an infrastructure manifest *)
} [@@deriving show]

(* ============================================================ *)
(* kind: infrastructure                                          *)
(* ============================================================ *)

type infra_node = {
  role: string;
  count: int;
  ram: string option;
  cpu: int option;
  boot: string option;
  os_image: string option;
  os_sha256: string option;
  isolated: bool;
  provisioning_profile: string option;  (** Nom d'un kind: provisioning_profile à appliquer *)
} [@@deriving show]

type network_segment = {
  seg_name: string;
  cidr: string;
  vlan: int option;
} [@@deriving show]

(** A filtering rule between two security zones. Rules are stateful:
    [Allow] opens new connections from [src_zone] to [dst_zone], replies to
    an established connection always pass, and anything not allowed is
    denied. *)
type fw_action = Allow | Deny [@@deriving show]

type firewall_rule = {
  action: fw_action;
  src_zone: string;
  dst_zone: string;
  flow: (string * string) option;
    (** declared flow the rule opens: (consumer service, consumed service) *)
  reason: string option;
} [@@deriving show]

(** Textual form, as printed by [hamac plan] and written in an
    infrastructure manifest: ["ALLOW internal -> public (analytics -> web_api)"],
    ["DENY public -> secure (no read up)"]. *)
let firewall_rule_to_string (r : firewall_rule) : string =
  let action = match r.action with Allow -> "ALLOW" | Deny -> "DENY" in
  let detail = match r.flow, r.reason with
    | Some (c, s), _ -> Printf.sprintf " (%s -> %s)" c s
    | None, Some why -> Printf.sprintf " (%s)" why
    | None, None -> ""
  in
  Printf.sprintf "%s %s -> %s%s" action r.src_zone r.dst_zone detail

(** Inverse of [firewall_rule_to_string]. A parenthesised detail of the
    form ["a -> b"] is read back as a flow, anything else as a reason. *)
let firewall_rule_of_string (s : string) : (firewall_rule, string) result =
  let s = String.trim s in
  let head, detail = match String.index_opt s '(' with
    | Some i when s.[String.length s - 1] = ')' ->
      (String.trim (String.sub s 0 i),
       Some (String.trim (String.sub s (i + 1) (String.length s - i - 2))))
    | _ -> (s, None)
  in
  let words = String.split_on_char ' ' head |> List.filter ((<>) "") in
  let flow_of d = match String.split_on_char ' ' d |> List.filter ((<>) "") with
    | [c; "->"; t] -> Some (c, t)
    | _ -> None
  in
  let mk action src_zone dst_zone =
    let flow = Option.bind detail flow_of in
    let reason = if flow = None then detail else None in
    Ok { action; src_zone; dst_zone; flow; reason }
  in
  match words with
  | ["ALLOW"; src; "->"; dst] -> mk Allow src dst
  | ["DENY"; src; "->"; dst] -> mk Deny src dst
  | _ -> Error (Printf.sprintf
      "invalid firewall rule '%s' (expected: ALLOW|DENY <zone> -> <zone> [(detail)])" s)

type infra_topology = {
  nodes: infra_node list;
  segments: network_segment list;
  firewall: firewall_rule list;
} [@@deriving show]

type infra_requirements = {
  min_nodes: int option;
  total_ram: string option;
  total_cpu: int option;
} [@@deriving show]

type infrastructure_manifest = {
  name: string;
  backend: string;           (** physical | qemu | kubernetes | docker-compose *)
  minimum_requirements: infra_requirements option;
  proposed_topology: infra_topology option;
  warnings: string list;
  certificate: string option;      (** experimental: resolution certificate *)
} [@@deriving show]

(* ============================================================ *)
(* kind: provisioning_profile (+ kind: bundle)                   *)
(* ============================================================ *)
(* Cf. doc/typst/provisioning.typ                                  *)

(** Valeur d'un paramètre de bundle, transmise au gabarit Jinja2 du bundle :
    celles d'un profil LOAF (texte, entier, liste) et celles qu'une machine
    reçoit par l'API de découverte (JSON). *)
type param_value =
  | PNull
  | PBool of bool
  | PInt of int
  | PFloat of float
  | PString of string
  | PList of param_value list
  | PObject of (string * param_value) list
[@@deriving show]

type os_image_spec = {
  os_image_name: string;    (** Identifiant logique ex. "debian-12-amd64" *)
  os_url: string;           (** URL téléchargeable de l'image *)
  os_sha256: string;        (** Hash pour vérification *)
  os_format: string;        (** qcow2 | raw | iso | netinstall *)
  os_family: string;        (** debian | ubuntu | fedora | ... — sélectionne
                                la variante de template cloud-init du bundle *)
  os_raw_zst_url: string;    (** URL du raw.zst dérivé pour install physique
                                  (bmaptool copy), vide si absent — le qcow2
                                  ci-dessus reste la référence, consommée
                                  directement par les VMs. Cf. §3.1 de
                                  provisioning.typ. *)
  os_raw_zst_sha256: string; (** Hash du raw.zst, vide si os_raw_zst_url l'est *)
  os_bmap_url: string;       (** URL du .bmap associé, vide si absent *)
} [@@deriving show]

(** Référence à un bundle depuis un provisioning_profile, avec les valeurs
    des paramètres à passer au template Jinja2 du bundle. *)
type bundle_ref = {
  bundle_name: string;
  bundle_params: (string * param_value) list;
} [@@deriving show]

type provisioning_profile_manifest = {
  pp_name: string;
  pp_os: os_image_spec;
  pp_bundles: bundle_ref list;     (** in the order of the cloud-init merge *)
  pp_cloud_init_extra: string option;  (** cloud-init (YAML) merged last *)
  pp_assurance: assurance option;  (** experimental: what an installed machine offers *)
} [@@deriving show]

(** Spécification d'un paramètre déclaré côté bundle.
    [param_type] est conservé en string brut pour rester extensible
    ("string", "int", "bool", "list[string]"). *)
type bundle_param_spec = {
  param_name: string;
  param_type: string;
  param_required: bool;
} [@@deriving show]

type bundle_manifest = {
  bdl_name: string;
  bdl_version: string;
  bdl_description: string;
  bdl_params: bundle_param_spec list;
  bdl_depends_on: string list;
  bdl_lifecycle: string;           (** install | converge (experimental) *)
  (* Le contenu (packages, users, runcmd...) vit désormais dans le(s)
     template(s) cloud-init du bundle (cloud-init[.<family>].yaml.j2),
     plus dans des champs packages/post_install séparés. *)
} [@@deriving show]

(* ============================================================ *)
(* Top-level manifest                                            *)
(* ============================================================ *)

type manifest =
  | MService of service_manifest
  | MStack of stack_manifest
  | MPattern of pattern_manifest
  | MInfrastructure of infrastructure_manifest
  | MProvisioningProfile of provisioning_profile_manifest
  | MBundle of bundle_manifest
  [@@deriving show]
