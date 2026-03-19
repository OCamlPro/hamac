(** Infrastructure simulator for hamac.

    Generates a docker-compose.yml that simulates a multi-node
    infrastructure using Docker-in-Docker containers.
    Each node is a DinD container. Services are deployed inside
    nodes via docker exec. Network isolation via docker networks. *)

open Manifest_types
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

(** Generate the init script that runs inside a DinD node.
    This script waits for Docker daemon, then pulls/runs services. *)
let generate_node_init_script
    ~(services : (service_manifest * (string * string) list) list)
  : string =
  let buf = Buffer.create 512 in
  Buffer.add_string buf "#!/bin/sh\n";
  Buffer.add_string buf "set -e\n";
  Buffer.add_string buf "# Wait for Docker daemon\n";
  Buffer.add_string buf "echo 'Waiting for Docker daemon...'\n";
  Buffer.add_string buf "while ! docker info >/dev/null 2>&1; do sleep 1; done\n";
  Buffer.add_string buf "echo 'Docker daemon ready'\n\n";

  (* Track replica index per service for unique container names *)
  let replica_counters : (string, int) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun ((svc : service_manifest), env_vars) ->
    let idx = match Hashtbl.find_opt replica_counters svc.name with
      | Some i -> i | None -> 0 in
    Hashtbl.replace replica_counters svc.name (idx + 1);
    let container_name = Printf.sprintf "%s-%d" svc.name idx in
    Buffer.add_string buf (Printf.sprintf "# Deploy %s (replica %d)\n" svc.name idx);

    (* Build env flags *)
    let env_flags = List.map (fun (k, v) ->
      Printf.sprintf "-e %s='%s'" k v
    ) env_vars |> String.concat " " in

    (* Port flags *)
    let port_flags = List.map (fun (p : port) ->
      Printf.sprintf "-p %d:%d" p.host p.container
    ) svc.ports |> String.concat " " in

    (match svc.artifact with
     | Some a when a.format = "oci-image" ->
       Buffer.add_string buf (Printf.sprintf "docker pull %s\n" a.path);
       Buffer.add_string buf (Printf.sprintf "docker run -d --name %s %s %s %s\n"
         container_name env_flags port_flags a.path)
     | _ ->
       (* For native binaries, use a minimal image and copy binary *)
       Buffer.add_string buf (Printf.sprintf
         "docker run -d --name %s %s %s debian:bookworm-slim sleep infinity\n"
         container_name env_flags port_flags);
       (match svc.artifact with
        | Some a ->
          Buffer.add_string buf (Printf.sprintf
            "docker cp %s %s:/app/service\n" a.path container_name);
          Buffer.add_string buf (Printf.sprintf
            "docker exec %s chmod +x /app/service\n" container_name);
          Buffer.add_string buf (Printf.sprintf
            "docker exec -d %s /app/service\n" container_name)
        | None -> ()));
    Buffer.add_string buf "\n"
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

(** Simple round-robin placement within a zone *)
let place_services
    ~(plan : Planner.plan)
    ~(resolution : resolution)
    (services : service_manifest list)
  : placement list =
  let placements : (string, placement) Hashtbl.t = Hashtbl.create 16 in

  (* Initialize empty nodes *)
  List.iter (fun (z : Planner.zone_info) ->
    let node_count = Planner.nodes_for_zone z in
    for i = 0 to node_count - 1 do
      let name = node_name z.zone_name i in
      Hashtbl.replace placements name {
        node = name;
        zone = z.zone_name;
        services = [];
      }
    done
  ) plan.zones;

  (* Place each service replica into nodes of its zone *)
  List.iter (fun (svc : service_manifest) ->
    let zone = Planner.service_zone svc in
    (* Collect injected env for this service *)
    let injected_env = List.fold_left (fun acc (w : resolved_wire) ->
      if w.consumer_name = svc.name then acc @ w.injected_env
      else acc
    ) [] resolution.wires in
    let all_env = svc.environment @ injected_env in

    (* Find nodes in this zone *)
    let zone_nodes = Hashtbl.fold (fun _ (p : placement) acc ->
      if p.zone = zone then p :: acc else acc
    ) placements [] |> List.sort (fun a b -> String.compare a.node b.node) in

    let max_replicas = Planner.service_max_replicas svc in
    let n_nodes = List.length zone_nodes in
    if n_nodes > 0 then
      for i = 0 to max_replicas - 1 do
        let target_node = List.nth zone_nodes (i mod n_nodes) in
        let current = Hashtbl.find placements target_node.node in
        Hashtbl.replace placements target_node.node {
          current with
          services = current.services @ [(svc, all_env)];
        }
      done
  ) services;

  Hashtbl.fold (fun _ v acc -> v :: acc) placements []
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
      if rp.instance_name = Printf.sprintf "%s-%s-%s"
           w.provider_name w.consumer_name w.consume_name then
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

  (* DinD node containers *)
  List.iter (fun (p : placement) ->
    let script_name = Printf.sprintf ".hamac/init-%s.sh" p.node in
    let script_content = generate_node_init_script ~services:p.services in
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

    (* Depends on providers that this node's services consume *)
    let deps = List.concat_map (fun ((svc : service_manifest), _) ->
      List.filter_map (fun (w : resolved_wire) ->
        if w.consumer_name = svc.name then
          Some (Printf.sprintf "%s-%s-%s" w.provider_name w.consumer_name w.consume_name)
        else None
      ) resolution.wires
    ) p.services |> List.sort_uniq String.compare in
    if deps <> [] then begin
      emit_line buf 2 "depends_on:";
      List.iter (fun dep ->
        let has_hc = List.exists (fun (rp : resolved_provider) ->
          rp.instance_name = dep && rp.provider.readiness <> None
        ) resolution.providers in
        if has_hc then begin
          emit_line buf 3 "%s:" dep;
          emit_line buf 4 "condition: service_healthy"
        end else
          emit_line buf 3 "- %s" dep
      ) deps
    end;

    emit_line buf 2 "networks:";
    emit_line buf 3 "- zone_%s" p.zone;
    emit_line buf 2 "restart: unless-stopped";
    Buffer.add_char buf '\n'
  ) placements;

  (* Networks — one per zone *)
  emit_line buf 0 "networks:";
  List.iteri (fun idx (z : Planner.zone_info) ->
    emit_line buf 1 "zone_%s:" z.zone_name;
    emit_line buf 2 "driver: bridge";
    emit_line buf 2 "ipam:";
    emit_line buf 3 "config:";
    emit_line buf 4 "- subnet: %s" (Planner.zone_cidr idx);
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
