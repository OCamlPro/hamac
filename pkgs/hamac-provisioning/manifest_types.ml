(** Manifest types for hamac.

    Structured OCaml types corresponding to the three manifest kinds
    defined in doc/MANIFEST_SPEC.md. *)

(* ============================================================ *)
(* Common types                                                  *)
(* ============================================================ *)

type artifact = {
  path: string;
  sha256: string;
  format: string;           (** native-linux-amd64 | oci-image | ... *)
} [@@deriving show]

type port = {
  host: int;
  container: int;
  protocol: string;         (** tcp | udp *)
} [@@deriving show]

type volume = {
  host_path: string;
  container_path: string;
  read_only: bool;
} [@@deriving show]

type route_label = {
  route: string;
  required_clearance: string list;
} [@@deriving show]

type security = {
  zone: string;              (** public | internal | secure | custom *)
  route_labels: route_label list;
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
  capability: string option;  (** database, cache, queue, storage *)
  service: string option;     (** reference to another service *)
  inject: (string * string) list;
} [@@deriving show]

type signature = {
  algorithm: string;
  public_key: string;
  value: string;
  signed_fields: string list;
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
  manifest_version: string;
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
  volumes: volume list;
  environment: (string * string) list;
  resources: resources option;
  replicas: int;
  autoscaling: autoscaling option;
  health_check: health_check option;
  metrics: metrics option;
  logging: logging option;
} [@@deriving show]

(* ============================================================ *)
(* kind: stack                                                   *)
(* ============================================================ *)

type stack_service_ref = {
  ref_path: string;
  replicas_override: int option;
  consumes_override: stack_consume_override list;
} [@@deriving show]

and stack_consume_override = {
  consume_name: string;
  provider: string;
} [@@deriving show]

type stack_manifest = {
  manifest_version: string;
  name: string;
  services: stack_service_ref list;
  infrastructure: string option;   (** path to infrastructure manifest *)
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

type firewall_rule = {
  rule: string;              (** raw rule string for now *)
} [@@deriving show]

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
  manifest_version: string;
  name: string;
  backend: string;           (** physical | qemu | kubernetes | docker-compose *)
  minimum_requirements: infra_requirements option;
  proposed_topology: infra_topology option;
  warnings: string list;
} [@@deriving show]

(* ============================================================ *)
(* kind: provisioning_profile (+ kind: bundle)                   *)
(* ============================================================ *)
(* Cf. doc/PROVISIONING_SPEC.md                                  *)

(** YAML value brut (params bundle, cloud_init_extra, etc.). *)
type yaml_value = Yaml.value
let pp_yaml_value fmt v =
  match Yaml.to_string v with
  | Ok s -> Format.fprintf fmt "%s" (String.trim s)
  | Error (`Msg m) -> Format.fprintf fmt "<invalid yaml: %s>" m

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
                                  PROVISIONING_SPEC.md. *)
  os_raw_zst_sha256: string; (** Hash du raw.zst, vide si os_raw_zst_url l'est *)
  os_bmap_url: string;       (** URL du .bmap associé, vide si absent *)
} [@@deriving show]

(** Référence à un bundle depuis un provisioning_profile, avec les valeurs
    des paramètres à passer au template Jinja2 du bundle. *)
type bundle_ref = {
  bundle_name: string;
  bundle_params: (string * yaml_value) list;
} [@@deriving show]

type provisioning_profile_manifest = {
  pp_manifest_version: string;
  pp_name: string;
  pp_os: os_image_spec;
  pp_bundles: bundle_ref list;
  pp_cloud_init_extra: yaml_value option;
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
  bdl_manifest_version: string;
  bdl_name: string;
  bdl_version: string;
  bdl_description: string;
  bdl_params: bundle_param_spec list;
  bdl_depends_on: string list;
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
  | MInfrastructure of infrastructure_manifest
  | MProvisioningProfile of provisioning_profile_manifest
  | MBundle of bundle_manifest
  [@@deriving show]
