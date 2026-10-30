(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Infrastructure simulator for hamac.

    Generates a docker-compose.yml that simulates a multi-node
    infrastructure using Docker-in-Docker containers.
    Each node is a DinD container. Services are deployed inside
    nodes via docker exec. Network isolation via docker networks. *)

open Hamac_manifest.Types
open Resolver

(* ============================================================ *)
(* YAML emitter (shared with compose_gen)                        *)
(* ============================================================ *)

let indent n buf =
  for _ = 1 to n do Buffer.add_string buf "  " done

let emit_line buf depth fmt =
  let k s = indent depth buf; Buffer.add_string buf s; Buffer.add_char buf '\n' in
  Printf.ksprintf k fmt

(* ============================================================ *)
(* Node naming                                                   *)
(* ============================================================ *)

(** Generate node container name *)
let node_name (zone : string) (index : int) : string =
  Printf.sprintf "node-%s-%d" zone (index + 1)

(* ============================================================ *)
(* Init script generation                                        *)
(* ============================================================ *)

(** Stateful filtering applied on a DinD node, derived from the plan's
    rules for the node's zone. Connections inside a zone are not filtered;
    replies to an allowed connection always pass. *)
type node_filter = {
  outbound: (string * (int * int)) list;
    (** subnet of a less sensitive zone this node may open connections to,
        with the host port range of the consumed service *)
  inbound: (string * (int * int)) list;
    (** address of a node of a more sensitive zone, attached to this zone's
        network, allowed to open connections to the given port range *)
  foreign: string list;
    (** addresses of all nodes of other zones attached to this zone's
        network: any other new connection from them is dropped *)
  others: string list;
    (** subnets of all other zones: any other new connection to or from
        them is dropped *)
}

(** iptables commands implementing a [node_filter]. Service containers run
    inside the node's own Docker daemon: their traffic crosses FORWARD, so
    each rule is set both in INPUT/OUTPUT (node-level traffic) and in
    DOCKER-USER (container traffic, where ports published with [-p] are
    matched on their original destination port). Docker ends DOCKER-USER
    with a RETURN rule: the chain is rebuilt so that ours come before it. *)
let filter_commands (f : node_filter) : string list =
  let range (lo, hi) = if lo = hi then string_of_int lo else Printf.sprintf "%d:%d" lo hi in
  let established chain =
    Printf.sprintf "iptables -I %s 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT" chain in
  let accept_out = List.concat_map (fun (subnet, r) ->
    [ Printf.sprintf "iptables -A OUTPUT -d %s -p tcp --dport %s -m conntrack --ctstate NEW -j ACCEPT" subnet (range r);
      Printf.sprintf "iptables -A DOCKER-USER -d %s -p tcp -m conntrack --ctstate NEW --ctorigdstport %s -j ACCEPT" subnet (range r) ]
  ) f.outbound in
  let accept_in = List.concat_map (fun (src, r) ->
    [ Printf.sprintf "iptables -A INPUT -s %s -p tcp --dport %s -m conntrack --ctstate NEW -j ACCEPT" src (range r);
      Printf.sprintf "iptables -A DOCKER-USER -s %s -p tcp -m conntrack --ctstate NEW --ctorigdstport %s -j ACCEPT" src (range r) ]
  ) f.inbound in
  let drop_foreign = List.concat_map (fun src ->
    [ Printf.sprintf "iptables -A INPUT -s %s -m conntrack --ctstate NEW -j DROP" src;
      Printf.sprintf "iptables -A DOCKER-USER -s %s -m conntrack --ctstate NEW -j DROP" src ]
  ) f.foreign in
  let drop_others = List.concat_map (fun subnet ->
    [ Printf.sprintf "iptables -A OUTPUT -d %s -m conntrack --ctstate NEW -j DROP" subnet;
      Printf.sprintf "iptables -A INPUT -s %s -m conntrack --ctstate NEW -j DROP" subnet;
      Printf.sprintf "iptables -A DOCKER-USER -d %s -m conntrack --ctstate NEW -j DROP" subnet;
      Printf.sprintf "iptables -A DOCKER-USER -s %s -m conntrack --ctstate NEW -j DROP" subnet ]
  ) f.others in
  match accept_out @ accept_in @ drop_foreign @ drop_others with
  | [] -> []
  | rules ->
    [ "iptables -F DOCKER-USER";
      established "INPUT"; established "OUTPUT"; established "DOCKER-USER" ]
    @ rules
    @ [ "iptables -A DOCKER-USER -j RETURN" ]

(** Generate the init script that runs inside a DinD node.
    This script waits for Docker daemon, applies the zone filtering,
    then pulls/runs services. *)
let generate_node_init_script
    ~(services : (service_manifest * (string * string) list) list)
    ~(filter : node_filter)
  : string =
  let buf = Buffer.create 512 in
  Buffer.add_string buf "#!/bin/sh\n";
  Buffer.add_string buf "set -e\n";
  Buffer.add_string buf "# Wait for Docker daemon\n";
  Buffer.add_string buf "echo 'Waiting for Docker daemon...'\n";
  Buffer.add_string buf "while ! docker info >/dev/null 2>&1; do sleep 1; done\n";
  Buffer.add_string buf "echo 'Docker daemon ready'\n\n";

  (* Enable inter-zone routing: disable reverse path filtering *)
  Buffer.add_string buf "# Enable backbone routing\n";
  Buffer.add_string buf "for iface in /proc/sys/net/ipv4/conf/*/rp_filter; do\n";
  Buffer.add_string buf "  echo 0 > \"$iface\" 2>/dev/null || true\n";
  Buffer.add_string buf "done\n\n";

  (* Zone filtering (Bell-LaPadula: no read up, read down only for
     declared flows), stateful *)
  (match filter_commands filter with
   | [] -> ()
   | cmds ->
     Buffer.add_string buf "# Zone filtering: no read up, read down only for declared flows\n";
     Buffer.add_string buf "echo 'Applying zone filtering...'\n";
     List.iter (fun c -> Buffer.add_string buf (c ^ "\n")) cmds;
     Buffer.add_string buf "echo 'Zone filtering applied'\n\n");

  (* Track replica index per service for unique container names *)
  let replica_counters : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun ((svc : service_manifest), env_vars) ->
    let idx = match Hashtbl.find_opt replica_counters svc.name with
      | Some i -> i | None -> 0 in
    Hashtbl.replace replica_counters svc.name (idx + 1);
    let container_name = Printf.sprintf "%s-%d" svc.name idx in
    Buffer.add_string buf (Printf.sprintf "# Deploy %s (replica %d)\n" svc.name idx);

    (* Idempotent: skip if container already exists and is running *)
    Buffer.add_string buf (Printf.sprintf
      "if docker inspect %s >/dev/null 2>&1; then\n" container_name);
    Buffer.add_string buf (Printf.sprintf
      "  echo '%s already exists, starting if stopped'\n" container_name);
    Buffer.add_string buf (Printf.sprintf
      "  docker start %s 2>/dev/null || true\n" container_name);
    Buffer.add_string buf "else\n";

    (* Build env flags *)
    let env_flags = List.map (fun (k, v) ->
      Printf.sprintf "-e %s='%s'" k v
    ) env_vars |> String.concat " " in

    (* Port flags — offset host port by replica index to avoid conflicts *)
    let port_flags = List.map (fun (p : port) ->
      Printf.sprintf "-p %d:%d" (p.container + idx) p.container
    ) svc.ports |> String.concat " " in

    (match svc.artifact with
     | Some a when a.format = "oci-image" ->
       Buffer.add_string buf (Printf.sprintf "  docker pull %s\n" a.path);
       Buffer.add_string buf (Printf.sprintf "  docker run -d --name %s %s %s %s\n"
         container_name env_flags port_flags a.path)
     | _ ->
       (* For native binaries, use a minimal image and copy binary *)
       Buffer.add_string buf (Printf.sprintf
         "  docker run -d --name %s %s %s debian:bookworm-slim sleep infinity\n"
         container_name env_flags port_flags);
       (match svc.artifact with
        | Some a ->
          Buffer.add_string buf (Printf.sprintf
            "  docker cp %s %s:/app/service\n" a.path container_name);
          Buffer.add_string buf (Printf.sprintf
            "  docker exec %s chmod +x /app/service\n" container_name);
          Buffer.add_string buf (Printf.sprintf
            "  docker exec -d %s /app/service\n" container_name)
        | None -> ()));
    Buffer.add_string buf "fi\n\n"
  ) services;

  Buffer.add_string buf "echo 'All services deployed'\n";
  Buffer.add_string buf "# Keep container alive\n";
  Buffer.add_string buf "tail -f /dev/null\n";
  Buffer.contents buf

(* ============================================================ *)
(* Placement: assign services to nodes                           *)
(* ============================================================ *)

type placement = {
  node: string;       (** node container name *)
  zone: string;
  services: (service_manifest * (string * string) list) list;
    (** services + their injected env vars *)
}

(** Where a consumed service is reached in the simulation: the node that
    hosts its first replica in the plan, and the host port of its first
    published port. *)
let service_endpoint ~(plan : Planner.plan) (svc : service_manifest) : string * string =
  let zone = Planner.service_zone svc in
  let node = match List.find_opt (fun (r : Planner.replica) ->
      r.service = svc.name && r.index = 1) plan.placement with
    | Some r -> r.node
    | None -> 0 in
  let host = node_name zone node in
  match svc.ports with
  | p :: _ -> (host, string_of_int p.container)
  | [] -> (host, "")

(** Host port range a service occupies on a node: replicas on the same node
    get consecutive host ports (see [generate_node_init_script]). *)
let service_port_range (svc : service_manifest) : (int * int) option =
  match svc.ports with
  | p :: _ -> Some (p.container, p.container + Planner.service_max_replicas svc - 1)
  | [] -> None

(** The nodes of the plan and the replicas it places on each
    ({!Planner.plan}), with the environment of each service. *)
let place_services
    ~(plan : Planner.plan)
    ~(resolution : resolution)
    (services : service_manifest list)
  : placement list =
  let env_of (svc : service_manifest) =
    let injected_env = List.fold_left (fun acc (w : resolved_wire) ->
      if w.consumer_name = svc.name then acc @ w.injected_env
      else acc
    ) [] resolution.wires in
    svc.environment @ injected_env in
  List.concat_map (fun (z : Planner.zone_info) ->
    List.init z.nodes (fun i ->
      let replicas = List.filter (fun (r : Planner.replica) ->
        r.zone = z.zone_name && r.node = i) plan.placement in
      { node = node_name z.zone_name i;
        zone = z.zone_name;
        services = List.filter_map (fun (r : Planner.replica) ->
          List.find_opt (fun (s : service_manifest) -> s.name = r.service) services
          |> Option.map (fun svc -> (svc, env_of svc))) replicas }))
    plan.zones
  |> List.sort (fun a b -> String.compare a.node b.node)

(* ============================================================ *)
(* Compose generation                                            *)
(* ============================================================ *)

(** Generate the infrastructure simulation docker-compose.yml *)
let generate
    ~(plan : Planner.plan)
    ~(services : service_manifest list)
    (resolution : resolution)
  : string * (string * string) list =
  (* (string * string) list = init script files to write *)
  let placements = place_services ~plan ~resolution services in
  let buf = Buffer.create 2048 in
  let scripts = ref [] in

  Buffer.add_string buf "# Generated by hamac (infrastructure simulation) — do not edit\n";
  emit_line buf 0 "services:";

  (* Provider instances — run in the zone of their consumer *)
  List.iter (fun (rp : resolved_provider) ->
    let image = match rp.provider.artifact with
      | Some a when a.format = "oci-image" -> a.path
      | _ -> rp.provider.name
    in
    emit_line buf 1 "%s:" rp.instance_name;
    emit_line buf 2 "image: %s" image;
    emit_line buf 2 "container_name: %s" rp.instance_name;
    if rp.resolved_env <> [] then begin
      emit_line buf 2 "environment:";
      List.iter (fun (k, v) ->
        emit_line buf 3 "%s: \"%s\"" k v
      ) rp.resolved_env
    end;
    (match rp.provider.readiness with
     | Some r when r.command <> [] ->
       emit_line buf 2 "healthcheck:";
       let vars = Compose_gen.provider_vars rp in
       let resolved_cmd = List.map (Resolver.substitute vars) r.command in
       let cmd = String.concat "\", \"" resolved_cmd in
       emit_line buf 3 "test: [\"CMD\", \"%s\"]" cmd;
       emit_line buf 3 "interval: %ds" r.readiness_interval;
       emit_line buf 3 "timeout: %ds" r.readiness_timeout;
       emit_line buf 3 "retries: 5"
     | _ -> ());
    emit_line buf 2 "restart: unless-stopped";
    (* Attach to zone networks of all consumers *)
    let consumer_zones = List.filter_map (fun (w : resolved_wire) ->
      if provider_instance w = Some rp.instance_name then
        let svc_opt = List.find_opt (fun (s : service_manifest) ->
          s.name = w.consumer_name) services in
        match svc_opt with
        | Some s -> Some (Planner.service_zone s)
        | None -> None
      else None
    ) resolution.wires |> List.sort_uniq String.compare in
    let zones_to_join = if consumer_zones = [] then ["default"] else consumer_zones in
    emit_line buf 2 "networks:";
    List.iter (fun z ->
      emit_line buf 3 "- zone_%s" z
    ) zones_to_join;
    Buffer.add_char buf '\n'
  ) resolution.providers;

  (* Build zone→subnet mapping for firewall rules *)
  let zone_subnets = List.mapi (fun i (z : Planner.zone_info) ->
    (z.zone_name, Planner.zone_cidr i)
  ) plan.zones in
  let rules = match plan.infrastructure.proposed_topology with
    | Some topo -> topo.firewall
    | None -> []
  in

  (* Networks of a node: its own zone + the zones it may open connections
     to (declared read-down flows). Nodes of a less sensitive zone are
     never attached to a more sensitive zone's network. *)
  let node_networks (p : placement) =
    p.zone :: List.filter_map (fun (r : firewall_rule) ->
      if r.action = Allow && r.src_zone = p.zone then Some r.dst_zone else None
    ) rules |> List.sort_uniq String.compare
  in

  (* Static addresses of the nodes on each zone network, so that filtering
     can name the nodes of another zone attached to it: own nodes first,
     then foreign ones, from .10; dynamic addresses (provider containers)
     are confined to the upper half of the subnet. *)
  let addresses = List.concat (List.mapi (fun i (z : Planner.zone_info) ->
    let attached = List.filter (fun p -> List.mem z.zone_name (node_networks p)) placements in
    let own, foreign = List.partition (fun p -> p.zone = z.zone_name) attached in
    List.mapi (fun k (p : placement) ->
      if k > 117 then
        failwith (Printf.sprintf "zone %s: too many nodes attached to its network" z.zone_name);
      ((p.node, z.zone_name), Printf.sprintf "10.%d.0.%d" (10 + i) (10 + k))
    ) (own @ foreign)
  ) plan.zones) in
  let address node zone = List.assoc_opt (node, zone) addresses in


  (* DinD node containers *)
  List.iter (fun (p : placement) ->
    let script_name = Printf.sprintf ".hamac/init-%s.sh" p.node in

    (* Zone filtering for this node, from the plan's rules *)
    let subnet z = List.assoc_opt z zone_subnets in
    let find_service name = List.find_opt (fun (s : service_manifest) -> s.name = name) services in
    let target_range (r : firewall_rule) =
      Option.bind r.flow (fun (_, t) -> Option.bind (find_service t) service_port_range) in
    let nodes_of zone = List.filter (fun (q : placement) -> q.zone = zone) placements in
    let outbound = List.filter_map (fun (r : firewall_rule) ->
      if r.action = Allow && r.src_zone = p.zone then
        match subnet r.dst_zone, target_range r with
        | Some sn, Some range -> Some (sn, range)
        | _ -> None
      else None
    ) rules in
    let inbound = List.concat_map (fun (r : firewall_rule) ->
      if r.action = Allow && r.dst_zone = p.zone then
        match target_range r with
        | Some range ->
          List.filter_map (fun (q : placement) ->
            Option.map (fun ip -> (ip, range)) (address q.node p.zone)
          ) (nodes_of r.src_zone)
        | None -> []
      else []
    ) rules in
    let foreign = List.filter_map (fun (q : placement) ->
      if q.zone = p.zone then None else address q.node p.zone
    ) placements in
    let others = List.filter_map (fun (z, sn) ->
      if z = p.zone then None else Some sn) zone_subnets in
    let filter = { outbound; inbound; foreign; others } in

    let script_content = generate_node_init_script ~services:p.services ~filter in
    scripts := (script_name, script_content) :: !scripts;

    emit_line buf 1 "%s:" p.node;
    emit_line buf 2 "image: docker:27-dind";
    emit_line buf 2 "container_name: %s" p.node;
    emit_line buf 2 "privileged: true";
    emit_line buf 2 "volumes:";
    emit_line buf 3 "- %s-data:/var/lib/docker" p.node;
    emit_line buf 3 "- ./%s:/init.sh:ro" script_name;
    emit_line buf 2 "entrypoint: [\"/bin/sh\", \"-c\", \"dockerd-entrypoint.sh & /init.sh\"]";
    emit_line buf 2 "environment:";
    emit_line buf 3 "DOCKER_TLS_CERTDIR: \"\"";

    (* Depends on providers that this node's services consume (map form:
       compose rejects mixing it with the list form) *)
    let deps = List.concat_map (fun ((svc : service_manifest), _) ->
      List.filter_map (fun (w : resolved_wire) ->
        if w.consumer_name = svc.name then provider_instance w else None
      ) resolution.wires
    ) p.services |> List.sort_uniq String.compare in
    if deps <> [] then begin
      emit_line buf 2 "depends_on:";
      List.iter (fun dep ->
        let has_hc = List.exists (fun (rp : resolved_provider) ->
          rp.instance_name = dep && rp.provider.readiness <> None
        ) resolution.providers in
        emit_line buf 3 "%s:" dep;
        emit_line buf 4 "condition: %s" (if has_hc then "service_healthy" else "service_started")
      ) deps
    end;

    (* Networks, with the node's static address on each *)
    emit_line buf 2 "networks:";
    List.iter (fun z ->
      emit_line buf 3 "zone_%s:" z;
      Option.iter (emit_line buf 4 "ipv4_address: %s") (address p.node z)
    ) (node_networks p);
    emit_line buf 2 "restart: unless-stopped";
    Buffer.add_char buf '\n'
  ) placements;

  (* Networks — one per zone + backbone for inter-zone *)
  emit_line buf 0 "networks:";
  List.iteri (fun idx (z : Planner.zone_info) ->
    emit_line buf 1 "zone_%s:" z.zone_name;
    emit_line buf 2 "driver: bridge";
    emit_line buf 2 "ipam:";
    emit_line buf 3 "config:";
    emit_line buf 4 "- subnet: %s" (Planner.zone_cidr idx);
    emit_line buf 5 "ip_range: 10.%d.0.128/25  # dynamic addresses; nodes are static" (10 + idx);
    if z.zone_name = "secure" then begin
      emit_line buf 2 "internal: true  # isolated zone"
    end
  ) plan.zones;
  Buffer.add_char buf '\n';

  (* Volumes — one per node *)
  emit_line buf 0 "volumes:";
  List.iter (fun (p : placement) ->
    emit_line buf 1 "%s-data:" p.node
  ) placements;

  (Buffer.contents buf, List.rev !scripts)

(* ============================================================ *)
(* Display placement summary                                     *)
(* ============================================================ *)

let display_placement (placements : placement list) =
  Logs.app (fun m -> m "Service placement:");
  List.iter (fun (p : placement) ->
    if p.services <> [] then begin
      Logs.app (fun m -> m "  %s [zone: %s]:" p.node p.zone);
      List.iter (fun ((svc : service_manifest), _) ->
        Logs.app (fun m -> m "    - %s" svc.name)
      ) p.services
    end else
      Logs.app (fun m -> m "  %s [zone: %s]: (empty)" p.node p.zone)
  ) placements
