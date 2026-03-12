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
(* Top-level manifest                                            *)
(* ============================================================ *)

type manifest =
  | MService of service_manifest
  | MStack of stack_manifest
  | MInfrastructure of infrastructure_manifest
  [@@deriving show]
