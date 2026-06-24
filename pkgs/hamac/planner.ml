(** Infrastructure planner for hamac.

    Infers infrastructure requirements from service manifests.
    Produces a proposed topology: nodes, network segments, firewall rules.
    This is the "zero touch" core — the user defines services,
    the planner figures out what infrastructure is needed. *)

open Hamac_provisioning.Manifest_types

(* ============================================================ *)
(* Resource parsing helpers                                      *)
(* ============================================================ *)

(** Parse memory string like "256Mi", "1Gi", "512M" to megabytes *)
let parse_memory_mb (s : string) : int =
  let len = String.length s in
  if len < 2 then 256 (* default *)
  else
    let suffix = String.sub s (len - 2) 2 in
    let num_str = String.sub s 0 (len - 2) in
    match suffix with
    | "Mi" | "MB" -> (try int_of_string num_str with _ -> 256)
    | "Gi" | "GB" -> (try int_of_string num_str * 1024 with _ -> 256)
    | _ ->
      (* Try single-char suffix: M, G *)
      let suffix1 = String.sub s (len - 1) 1 in
      let num_str1 = String.sub s 0 (len - 1) in
      match suffix1 with
      | "M" -> (try int_of_string num_str1 with _ -> 256)
      | "G" -> (try int_of_string num_str1 * 1024 with _ -> 256)
      | _ -> 256

(** Parse CPU string like "0.5", "1", "2" to millicores *)
let parse_cpu_milli (s : string) : int =
  try
    let f = float_of_string s in
    int_of_float (f *. 1000.0)
  with _ -> 500

(* ============================================================ *)
(* Zone extraction                                               *)
(* ============================================================ *)

type zone_info = {
  zone_name: string;
  services: string list;
  total_memory_mb: int;
  total_cpu_milli: int;
  total_replicas: int;
}

(** Extract zone name from a service (default: "default") *)
let service_zone (svc : service_manifest) : string =
  match svc.security with
  | Some s -> s.zone
  | None -> "default"

(** Extract memory requirement per replica in MB *)
let service_memory_mb (svc : service_manifest) : int =
  match svc.resources with
  | Some r -> (match r.memory_limit with
    | Some m -> parse_memory_mb m
    | None -> 256)
  | None -> 256

(** Extract CPU requirement per replica in millicores *)
let service_cpu_milli (svc : service_manifest) : int =
  match svc.resources with
  | Some r -> (match r.cpu_limit with
    | Some c -> parse_cpu_milli c
    | None -> 500)
  | None -> 500

(** Max replicas considering autoscaling *)
let service_max_replicas (svc : service_manifest) : int =
  match svc.autoscaling with
  | Some a -> a.max_replicas
  | None -> svc.replicas

(** Group services by security zone and aggregate resources *)
let compute_zones (services : service_manifest list) : zone_info list =
  let tbl : (string, zone_info) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun (svc : service_manifest) ->
    let zone = service_zone svc in
    let replicas = service_max_replicas svc in
    let mem = service_memory_mb svc * replicas in
    let cpu = service_cpu_milli svc * replicas in
    let current = match Hashtbl.find_opt tbl zone with
      | Some z -> z
      | None -> { zone_name = zone; services = []; total_memory_mb = 0;
                  total_cpu_milli = 0; total_replicas = 0 }
    in
    Hashtbl.replace tbl zone {
      zone_name = zone;
      services = svc.name :: current.services;
      total_memory_mb = current.total_memory_mb + mem;
      total_cpu_milli = current.total_cpu_milli + cpu;
      total_replicas = current.total_replicas + replicas;
    }
  ) services;
  Hashtbl.fold (fun _ v acc -> v :: acc) tbl []
  |> List.sort (fun a b -> String.compare a.zone_name b.zone_name)

(* ============================================================ *)
(* Topology inference                                            *)
(* ============================================================ *)

(** Standard node sizes for simulation *)
let node_ram_mb = 4096    (* 4 GB per node *)
let node_cpu_milli = 4000 (* 4 cores per node *)

(** Compute how many nodes a zone needs *)
let nodes_for_zone (z : zone_info) : int =
  let by_ram = (z.total_memory_mb + node_ram_mb - 1) / node_ram_mb in
  let by_cpu = (z.total_cpu_milli + node_cpu_milli - 1) / node_cpu_milli in
  max 1 (max by_ram by_cpu)

(** Zone to CIDR mapping (deterministic) *)
let zone_cidr (zone_index : int) : string =
  Printf.sprintf "10.%d.0.0/24" (10 + zone_index)

(** Zone to VLAN ID (deterministic) *)
let zone_vlan (zone_index : int) : int =
  100 + zone_index

(** Generate firewall rules between zones.
    Bell-LaPadula: information flows UP only (public -> internal -> secure).
    Same zone: allow all. Higher to lower: deny by default. *)
let zone_order = ["public"; "default"; "internal"; "secure"]

let zone_level (zone : string) : int =
  let rec aux i = function
    | [] -> 1  (* unknown zones treated as "default" *)
    | z :: _ when z = zone -> i
    | _ :: rest -> aux (i + 1) rest
  in
  aux 0 zone_order

let generate_firewall_rules (zones : zone_info list) : firewall_rule list =
  let zone_names = List.map (fun z -> z.zone_name) zones in
  List.concat_map (fun src ->
    List.filter_map (fun dst ->
      if src = dst then None
      else
        let src_level = zone_level src in
        let dst_level = zone_level dst in
        if src_level <= dst_level then
          (* Lower can reach higher — allow *)
          Some { rule = Printf.sprintf "ALLOW %s -> %s" src dst }
        else
          (* Higher cannot initiate to lower — deny *)
          Some { rule = Printf.sprintf "DENY %s -> %s (Bell-LaPadula)" src dst }
    ) zone_names
  ) zone_names

(* ============================================================ *)
(* Plan generation                                               *)
(* ============================================================ *)

type plan = {
  infrastructure: infrastructure_manifest;
  zones: zone_info list;
  warnings: string list;
}

(** Generate an infrastructure proposal from service manifests *)
let plan ~(name : string) (services : service_manifest list) : plan =
  let zones = compute_zones services in
  let warnings = ref [] in

  (* Generate nodes — one group per zone *)
  let nodes = List.map (fun (z : zone_info) ->
    let count = nodes_for_zone z in
    if count > 10 then
      warnings := (Printf.sprintf "Zone '%s' requires %d nodes — consider reviewing resource limits"
        z.zone_name count) :: !warnings;
    {
      role = z.zone_name;
      count;
      ram = Some (Printf.sprintf "%dMi" node_ram_mb);
      cpu = Some (node_cpu_milli / 1000);
      boot = None;
      os_image = Some "debian:bookworm-slim";
      os_sha256 = None;
      isolated = z.zone_name = "secure";
      provisioning_profile = None;
    }
  ) zones in

  (* Generate network segments — one per zone *)
  let segments = List.mapi (fun i (z : zone_info) ->
    {
      seg_name = z.zone_name;
      cidr = zone_cidr i;
      vlan = Some (zone_vlan i);
    }
  ) zones in

  (* Firewall rules *)
  let firewall = generate_firewall_rules zones in

  let infrastructure = {
    manifest_version = "1.0";
    name = name ^ "-infra";
    backend = "docker-compose";
    minimum_requirements = Some {
      min_nodes = Some (List.fold_left (fun acc n -> acc + n.count) 0 nodes);
      total_ram = Some (Printf.sprintf "%dMi"
        (List.fold_left (fun acc (z : zone_info) -> acc + z.total_memory_mb) 0 zones));
      total_cpu = Some
        (List.fold_left (fun acc (z : zone_info) -> acc + z.total_cpu_milli) 0 zones / 1000);
    };
    proposed_topology = Some {
      nodes;
      segments;
      firewall;
    };
    warnings = List.rev !warnings;
  } in

  { infrastructure; zones; warnings = List.rev !warnings }

(* ============================================================ *)
(* Display                                                       *)
(* ============================================================ *)

let display_plan (p : plan) =
  let infra = p.infrastructure in
  Logs.app (fun m -> m "Infrastructure proposal: %s" infra.name);
  Logs.app (fun m -> m "");

  (* Requirements *)
  (match infra.minimum_requirements with
   | Some req ->
     Logs.app (fun m -> m "Minimum requirements:");
     (match req.min_nodes with Some n -> Logs.app (fun m -> m "  Nodes: %d" n) | None -> ());
     (match req.total_ram with Some r -> Logs.app (fun m -> m "  RAM: %s" r) | None -> ());
     (match req.total_cpu with Some c -> Logs.app (fun m -> m "  CPU: %d cores" c) | None -> ());
     Logs.app (fun m -> m "")
   | None -> ());

  (* Zones *)
  Logs.app (fun m -> m "Zones:");
  List.iter (fun (z : zone_info) ->
    Logs.app (fun m -> m "  %s: %d service(s), %d replica(s), %d MB RAM, %d mCPU"
      z.zone_name (List.length z.services) z.total_replicas
      z.total_memory_mb z.total_cpu_milli);
    List.iter (fun svc ->
      Logs.app (fun m -> m "    - %s" svc)
    ) (List.rev z.services)
  ) p.zones;
  Logs.app (fun m -> m "");

  (* Topology *)
  (match infra.proposed_topology with
   | Some topo ->
     Logs.app (fun m -> m "Proposed topology:");
     List.iter (fun (n : infra_node) ->
       Logs.app (fun m -> m "  %dx node [%s] — %s RAM, %d CPU%s"
         n.count n.role
         (Option.value ~default:"?" n.ram)
         (Option.value ~default:0 n.cpu)
         (if n.isolated then " (isolated)" else ""))
     ) topo.nodes;
     Logs.app (fun m -> m "");

     Logs.app (fun m -> m "Network segments:");
     List.iter (fun (s : network_segment) ->
       Logs.app (fun m -> m "  %s: %s (VLAN %d)"
         s.seg_name s.cidr (Option.value ~default:0 s.vlan))
     ) topo.segments;
     Logs.app (fun m -> m "");

     if topo.firewall <> [] then begin
       Logs.app (fun m -> m "Firewall rules:");
       List.iter (fun (r : firewall_rule) ->
         Logs.app (fun m -> m "  %s" r.rule)
       ) topo.firewall;
       Logs.app (fun m -> m "")
     end
   | None -> ());

  (* Warnings *)
  List.iter (fun w ->
    Logs.warn (fun m -> m "%s" w)
  ) p.warnings
