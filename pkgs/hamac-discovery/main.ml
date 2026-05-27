(** SIESTE Infrastructure Discovery Server

    Minimal REST API for node registration, discovery, and service deployment.
    Nodes boot via PXE and register themselves with this server.

    Endpoints:
    - POST /register                - Register a new node
    - GET  /nodes                   - List all discovered nodes
    - GET  /nodes/:id               - Get specific node info
    - GET  /nodes/:id/cloud-init    - Get cloud-init config for provisioning
    - DELETE /nodes/:id             - Remove a node
    - GET  /health                  - Health check
    - GET  /config                  - Get cluster configuration
    - POST /config                  - Update cluster configuration
    - GET  /images                  - List available OS images
    - GET  /images/:name            - Download OS image
    - GET  /services                - List deployed services
    - POST /services                - Deploy a service
    - GET  /services/:name          - Get service status
    - DELETE /services/:name        - Remove a service
    - POST /constraints/check       - Check infrastructure constraints
    - GET  /dashboard               - Visual dashboard (HTML)
    - GET  /events                  - Server-Sent Events stream
    - GET  /api/state               - Full state JSON
*)

open Lwt.Infix

(** Node information *)
type node = {
  id: string;
  hostname: string;
  ip_address: string;
  mac_address: string;
  cpus: int;
  memory_mb: int;
  disk_gb: int;
  registered_at: float;
  last_seen: float;
  metadata: (string * string) list;
}

(** Service information *)
type service = {
  svc_name: string;
  runtime: string;
  ports: int list;
  replicas: int;
  replicas_ready: int;
  status: string;  (* pending, deploying, running, failed *)
  binary_path: string option;
  image: string option;
  env: (string * string) list;
  deployed_at: float;
  endpoints: string list;
}

(** Provisioning record pushed by hamac for a given MAC address.
    Cloud-init et iPXE sont déjà rendus (le discovery ne sait pas ce qu'est
    un bundle, cf. doc/PROVISIONING_SPEC.md section 7.1). *)
type provisioning_record = {
  pr_profile_name: string;
  pr_cloud_init: string;        (* YAML, préfixé par #cloud-config *)
  pr_ipxe_script: string;
  pr_os_image_url: string;
  pr_os_image_sha256: string;
  pr_os_format: string;
  pr_created_at: float;
}

(** MAC adresse autorisée à recevoir une réponse PXE.
    Géré par l'admin via l'UI web ou l'API REST. Mirroré sur dnsmasq via
    /api/allowed-macs/dnsmasq-hostsfile (polling sidecar dans hamac-pxe). *)
type allowed_mac_entry = {
  am_mac: string;          (* MAC normalisée lowercase *)
  am_label: string;        (* description humaine, ex: "Thinkpad d'Amenah" *)
  am_added_by: string;     (* utilisateur OIDC qui a ajouté (vide si pas d'auth) *)
  am_added_at: float;      (* timestamp Unix *)
}

(** Machine = une MAC + un profil du catalogue + des params par-machine.
    Couche "haute" (mode b, IT) : le discovery rend lui-meme le cloud-init
    a partir de (profil catalogue + params), produit un provisioning_record
    et whiteliste la MAC. Cf. doc/DECISIONS.md (2026-05-26). *)
type machine = {
  mc_mac: string;                          (* MAC normalisee *)
  mc_profile_name: string;                 (* reference au catalogue *)
  mc_params: (string * Yojson.Safe.t) list;(* params par-machine (username, ssh...) *)
  mc_status: string;                       (* pending | installed *)
  mc_created_at: float;
  mc_updated_at: float;
}

(** Global state - in production, use a database *)
let nodes : (string, node) Hashtbl.t = Hashtbl.create 16
let services : (string, service) Hashtbl.t = Hashtbl.create 16
let provisioning : (string, provisioning_record) Hashtbl.t = Hashtbl.create 16
let allowed_macs : (string, allowed_mac_entry) Hashtbl.t = Hashtbl.create 16
let machines : (string, machine) Hashtbl.t = Hashtbl.create 16
let node_counter = ref 0

(** Répertoire de persistance des profils de provisioning.
    Override via $HAMAC_DISCOVERY_STATE. *)
let state_dir =
  try Sys.getenv "HAMAC_DISCOVERY_STATE"
  with Not_found -> "/var/lib/hamac-discovery"

let provisioning_dir () = Filename.concat state_dir "provisioning"
let allowed_macs_file () = Filename.concat state_dir "allowed-macs.json"
let machines_dir () = Filename.concat state_dir "machines"
let custom_profiles_dir () = Filename.concat state_dir "profiles"

(** Profils "built-in" embarques dans l'image (seed du catalogue).
    Override via $HAMAC_PROFILES_DIR. *)
let builtin_profiles_dir =
  try Sys.getenv "HAMAC_PROFILES_DIR"
  with Not_found -> "/usr/share/hamac/profiles"

(** Repertoire des bundles (pour lire les schemas de params). Override via
    $HAMAC_BUNDLES_DIR (lu aussi par provisioning_gen). *)
let bundles_dir =
  try Sys.getenv "HAMAC_BUNDLES_DIR"
  with Not_found -> "/usr/share/hamac/bundles"

(** Normalise une MAC : lowercase, supprime les espaces.
    Conserve les ":" pour rester lisible côté disque. *)
let normalize_mac (mac : string) : string =
  String.trim mac |> String.lowercase_ascii

(** SSE clients - list of push functions *)
let sse_clients : (string -> unit) list ref = ref []
let sse_mutex = Lwt_mutex.create ()

(** Broadcast event to all SSE clients *)
let broadcast_event event_name data =
  let msg = Printf.sprintf "event: %s\ndata: %s\n\n" event_name
    (Yojson.Safe.to_string data) in
  Lwt_mutex.with_lock sse_mutex (fun () ->
    List.iter (fun push -> try push msg with _ -> ()) !sse_clients;
    Lwt.return_unit
  )

(** Generate unique node ID *)
let generate_id () =
  incr node_counter;
  Printf.sprintf "node-%04d" !node_counter

(** Simple scheduler - selects best node for deployment based on available resources *)
let schedule_service replicas =
  (* Get all healthy nodes (seen in last 60 seconds) *)
  let now = Unix.gettimeofday () in
  let healthy_nodes = Hashtbl.fold (fun _ node acc ->
    if now -. node.last_seen < 60.0 then node :: acc else acc
  ) nodes [] in

  if List.length healthy_nodes = 0 then
    []
  else begin
    (* Sort by available memory (descending) - simple heuristic *)
    let sorted = List.sort (fun a b -> compare b.memory_mb a.memory_mb) healthy_nodes in
    (* Take up to 'replicas' nodes *)
    let rec take n lst = match n, lst with
      | 0, _ | _, [] -> []
      | n, x :: xs -> x :: take (n - 1) xs
    in
    take replicas sorted
  end

(** Send deploy command to a specific node via SSE *)
let send_deploy_command target_node_id service_name port ?binary_url () =
  let base_fields = [
    ("service", `String service_name);
    ("port", `Int port);
    ("target", `String target_node_id);
    ("timestamp", `Float (Unix.gettimeofday ()));
  ] in
  let deploy_event = `Assoc (
    match binary_url with
    | Some url -> ("binary_url", `String url) :: base_fields
    | None -> base_fields
  ) in
  Printf.printf "[SCHEDULER] Deploying %s to node %s on port %d (binary: %s)\n%!"
    service_name target_node_id port (Option.value binary_url ~default:"<default>");
  broadcast_event "deploy" deploy_event

(** Send stop command to a specific node via SSE *)
let send_stop_command target_node_id service_name =
  let stop_event = `Assoc [
    ("service", `String service_name);
    ("target", `String target_node_id);
    ("timestamp", `Float (Unix.gettimeofday ()));
  ] in
  Printf.printf "[SCHEDULER] Stopping %s on node %s\n%!" service_name target_node_id;
  broadcast_event "stop" stop_event

(** JSON serialization *)
let node_to_json node : Yojson.Safe.t =
  `Assoc [
    ("id", `String node.id);
    ("hostname", `String node.hostname);
    ("ip_address", `String node.ip_address);
    ("mac_address", `String node.mac_address);
    ("cpus", `Int node.cpus);
    ("memory_mb", `Int node.memory_mb);
    ("disk_gb", `Int node.disk_gb);
    ("registered_at", `Float node.registered_at);
    ("last_seen", `Float node.last_seen);
    ("metadata", `Assoc (List.map (fun (k, v) -> (k, `String v)) node.metadata));
  ]

let nodes_to_json () : Yojson.Safe.t =
  let node_list = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [] in
  let sorted = List.sort (fun a b -> compare a.registered_at b.registered_at) node_list in
  `Assoc [
    ("count", `Int (List.length sorted));
    ("nodes", `List (List.map node_to_json sorted));
  ]

(** JSON serialization for services *)
let service_to_json svc : Yojson.Safe.t =
  `Assoc [
    ("name", `String svc.svc_name);
    ("runtime", `String svc.runtime);
    ("ports", `List (List.map (fun p -> `Int p) svc.ports));
    ("replicas", `Int svc.replicas);
    ("replicas_ready", `Int svc.replicas_ready);
    ("status", `String svc.status);
    ("binary_path", match svc.binary_path with Some p -> `String p | None -> `Null);
    ("image", match svc.image with Some i -> `String i | None -> `Null);
    ("env", `Assoc (List.map (fun (k, v) -> (k, `String v)) svc.env));
    ("deployed_at", `Float svc.deployed_at);
    ("endpoints", `List (List.map (fun e -> `String e) svc.endpoints));
  ]

let services_to_json () : Yojson.Safe.t =
  let svc_list = Hashtbl.fold (fun _ svc acc -> svc :: acc) services [] in
  let sorted = List.sort (fun a b -> compare a.deployed_at b.deployed_at) svc_list in
  `Assoc [
    ("count", `Int (List.length sorted));
    ("services", `List (List.map service_to_json sorted));
  ]

(** Parse node registration request *)
let parse_register_request body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let hostname = json |> member "hostname" |> to_string_option |> Option.value ~default:"unknown" in
    let ip_address = json |> member "ip_address" |> to_string in
    let mac_address = json |> member "mac_address" |> to_string in
    let cpus = json |> member "cpus" |> to_int_option |> Option.value ~default:1 in
    let memory_mb = json |> member "memory_mb" |> to_int_option |> Option.value ~default:512 in
    let disk_gb = json |> member "disk_gb" |> to_int_option |> Option.value ~default:10 in
    let metadata =
      match json |> member "metadata" with
      | `Assoc pairs -> List.map (fun (k, v) -> (k, to_string v)) pairs
      | _ -> []
    in
    Ok (hostname, ip_address, mac_address, cpus, memory_mb, disk_gb, metadata)
  with e ->
    Error (Printexc.to_string e)

(** Find node by MAC address (for re-registration) *)
let find_by_mac mac =
  Hashtbl.fold (fun id node acc ->
    if node.mac_address = mac then Some (id, node) else acc
  ) nodes None

(** HTTP response helpers *)
let json_headers = Cohttp.Header.of_list [
  ("Content-Type", "application/json");
  ("Access-Control-Allow-Origin", "*");
  ("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS");
  ("Access-Control-Allow-Headers", "Content-Type");
]

let respond_json ~status body =
  let body_str = Yojson.Safe.to_string body in
  Cohttp_lwt_unix.Server.respond_string ~status ~headers:json_headers ~body:body_str ()

let respond_error code message =
  respond_json ~status:(`Code code) (`Assoc [
    ("error", `String message);
    ("code", `Int code);
  ])

(** Handle POST /register *)
let handle_register body_str client_ip =
  match parse_register_request body_str with
  | Error msg ->
      respond_error 400 ("Invalid request: " ^ msg)
  | Ok (hostname, ip_address, mac_address, cpus, memory_mb, disk_gb, metadata) ->
      let now = Unix.gettimeofday () in
      (* Check if node already registered (by MAC) *)
      let (id, is_new) = match find_by_mac mac_address with
        | Some (existing_id, _) -> (existing_id, false)
        | None -> (generate_id (), true)
      in
      let ip = if ip_address = "" then client_ip else ip_address in
      let node = {
        id;
        hostname;
        ip_address = ip;
        mac_address;
        cpus;
        memory_mb;
        disk_gb;
        registered_at = (if is_new then now else
          match Hashtbl.find_opt nodes id with
          | Some n -> n.registered_at
          | None -> now);
        last_seen = now;
        metadata;
      } in
      Hashtbl.replace nodes id node;
      Printf.printf "[%s] Node %s (%s): %s @ %s - %d CPUs, %dMB RAM, %dGB disk\n%!"
        (if is_new then "NEW" else "UPDATE")
        id hostname mac_address ip cpus memory_mb disk_gb;
      (* Broadcast event to dashboard clients *)
      let event_type = if is_new then "node_added" else "node_updated" in
      Lwt.async (fun () -> broadcast_event event_type (node_to_json node));
      respond_json ~status:(if is_new then `Created else `OK) (node_to_json node)

(** Handle GET /nodes *)
let handle_list_nodes () =
  respond_json ~status:`OK (nodes_to_json ())

(** Handle GET /nodes/:id *)
let handle_get_node id =
  match Hashtbl.find_opt nodes id with
  | Some node -> respond_json ~status:`OK (node_to_json node)
  | None -> respond_error 404 ("Node not found: " ^ id)

(** Handle DELETE /nodes/:id *)
let handle_delete_node id =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      Hashtbl.remove nodes id;
      Printf.printf "[DELETE] Removed node %s (%s)\n%!" id node.hostname;
      (* Broadcast event to dashboard clients *)
      Lwt.async (fun () -> broadcast_event "node_removed" (`Assoc [
        ("id", `String id);
        ("hostname", `String node.hostname);
      ]));
      respond_json ~status:`OK (`Assoc [("deleted", `String id)])
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Handle GET /health *)
let handle_health () =
  respond_json ~status:`OK (`Assoc [
    ("status", `String "ok");
    ("nodes", `Int (Hashtbl.length nodes));
    ("uptime", `Float (Unix.gettimeofday ()));
  ])

(** Cluster configuration - mutable state *)
let k3s_url = ref (try Sys.getenv "K3S_URL" with _ -> "")
let k3s_token = ref (try Sys.getenv "K3S_TOKEN" with _ -> "")
let k3s_version = ref (try Sys.getenv "K3S_VERSION" with _ -> "v1.31.4+k3s1")
let image_url = ref (try Sys.getenv "IMAGE_URL" with _ -> "")
let images_dir = ref (try Sys.getenv "IMAGES_DIR" with _ -> "./images")

(** Handle GET /config *)
let handle_get_config () =
  respond_json ~status:`OK (`Assoc [
    ("k3s_url", `String !k3s_url);
    ("k3s_token", `String !k3s_token);
    ("k3s_version", `String !k3s_version);
    ("image_url", `String !image_url);
    ("images_dir", `String !images_dir);
    ("has_control_plane", `Bool (!k3s_url <> ""));
  ])

(** Handle POST /config - update cluster config *)
let handle_set_config body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    (match json |> member "k3s_url" |> to_string_option with
     | Some url -> k3s_url := url
     | None -> ());
    (match json |> member "k3s_token" |> to_string_option with
     | Some token -> k3s_token := token
     | None -> ());
    (match json |> member "k3s_version" |> to_string_option with
     | Some version -> k3s_version := version
     | None -> ());
    (match json |> member "image_url" |> to_string_option with
     | Some url -> image_url := url
     | None -> ());
    (match json |> member "images_dir" |> to_string_option with
     | Some dir -> images_dir := dir
     | None -> ());
    Printf.printf "[CONFIG] Updated: k3s_url=%s has_token=%b image_url=%s\n%!" !k3s_url (!k3s_token <> "") !image_url;
    respond_json ~status:`OK (`Assoc [("status", `String "updated")])
  with e ->
    respond_error 400 ("Invalid config: " ^ Printexc.to_string e)

(** Generate cloud-init user-data for a node *)
let generate_cloud_init node =
  let k3s_url' = !k3s_url in
  let k3s_token' = !k3s_token in
  let k3s_version' = !k3s_version in

  (* Determine node role from metadata *)
  let role = List.assoc_opt "role" node.metadata |> Option.value ~default:"worker" in
  let is_first_control_plane = (role = "control-plane" || role = "master") && k3s_url' = "" in

  (* Build k3s install command *)
  let k3s_install =
    if is_first_control_plane then
      (* First control plane - initialize cluster *)
      Printf.sprintf {|
# Initialize k3s control plane
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="%s" sh -s - server \
  --cluster-init \
  --tls-san %s \
  --write-kubeconfig-mode 644

# Wait for k3s to be ready
sleep 10

# Get join token and URL for other nodes
K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
K3S_URL="https://%s:6443"

# Register token back to discovery server
curl -X POST http://${DISCOVERY_SERVER}/config \
  -H "Content-Type: application/json" \
  -d "{\"k3s_url\": \"$K3S_URL\", \"k3s_token\": \"$K3S_TOKEN\"}"
|} k3s_version' node.ip_address node.ip_address
    else if role = "control-plane" || role = "master" then
      (* Additional control plane *)
      Printf.sprintf {|
# Join as control plane
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="%s" K3S_URL="%s" K3S_TOKEN="%s" sh -s - server
|} k3s_version' k3s_url' k3s_token'
    else
      (* Worker node *)
      Printf.sprintf {|
# Join as worker
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="%s" K3S_URL="%s" K3S_TOKEN="%s" sh -s - agent
|} k3s_version' k3s_url' k3s_token'
  in

  (* Generate cloud-init YAML *)
  Printf.sprintf {|#cloud-config
# SIESTE Auto-generated cloud-init for %s
# Generated at: %s
# Role: %s

hostname: %s
fqdn: %s.sieste.local
manage_etc_hosts: true

# Update and install prerequisites
package_update: true
package_upgrade: true
packages:
  - curl
  - wget
  - ca-certificates
  - open-iscsi
  - nfs-common

# Write node metadata
write_files:
  - path: /etc/sieste/node.json
    content: |
      {
        "id": "%s",
        "hostname": "%s",
        "ip_address": "%s",
        "mac_address": "%s",
        "role": "%s",
        "discovery_server": "${DISCOVERY_SERVER:-http://10.99.0.1:8877}"
      }
    permissions: '0644'

  - path: /etc/sieste/install-k3s.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      DISCOVERY_SERVER="${DISCOVERY_SERVER:-http://10.99.0.1:8877}"
      echo "[SIESTE] Installing k3s for role: %s"
      %s
      echo "[SIESTE] k3s installation complete"

# Run k3s installation
runcmd:
  - echo "[SIESTE] Starting provisioning for %s"
  - mkdir -p /etc/sieste
  - export DISCOVERY_SERVER="${DISCOVERY_SERVER:-http://10.99.0.1:8877}"
  - /etc/sieste/install-k3s.sh
  - echo "[SIESTE] Provisioning complete"

# Final message
final_message: "SIESTE node %s provisioned in $UPTIME seconds"
|}
    node.hostname
    (let t = Unix.gmtime (Unix.gettimeofday ()) in
     Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
       (1900 + t.Unix.tm_year) (1 + t.Unix.tm_mon) t.Unix.tm_mday
       t.Unix.tm_hour t.Unix.tm_min t.Unix.tm_sec)
    role
    node.hostname
    node.hostname
    node.id node.hostname node.ip_address node.mac_address role
    role k3s_install
    node.hostname
    node.hostname

(** Handle GET /nodes/:id/cloud-init *)
let handle_cloud_init id =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      (* Si un provisioning_record existe pour la MAC de ce nœud (poussé
         par hamac), il prend le dessus sur le cloud-init K3s historique.
         Cf. doc/PROVISIONING_SPEC.md section 7.3. *)
      let mac_key = normalize_mac node.mac_address in
      let cloud_init = match Hashtbl.find_opt provisioning mac_key with
        | Some r -> r.pr_cloud_init
        | None -> generate_cloud_init node
      in
      let headers = Cohttp.Header.of_list [
        ("Content-Type", "text/yaml; charset=utf-8");
        ("Content-Disposition", Printf.sprintf "attachment; filename=\"%s-cloud-init.yaml\"" node.hostname);
      ] in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:cloud_init ()
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Handle POST /nodes/:id/heartbeat - update last_seen *)
let handle_heartbeat id =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      let updated = { node with last_seen = Unix.gettimeofday () } in
      Hashtbl.replace nodes id updated;
      respond_json ~status:`OK (`Assoc [("status", `String "ok")])
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Handle GET /nodes/:id/services - get services assigned to this node *)
let handle_node_services id =
  match Hashtbl.find_opt nodes id with
  | Some _node ->
      (* For now, assign all services to all nodes - in production, use scheduler *)
      let svc_list = Hashtbl.fold (fun _ svc acc ->
        if svc.status = "deploying" || svc.status = "running" then
          `Assoc [
            ("name", `String svc.svc_name);
            ("runtime", `String svc.runtime);
            ("ports", `List (List.map (fun p -> `Int p) svc.ports));
          ] :: acc
        else acc
      ) services [] in
      respond_json ~status:`OK (`Assoc [
        ("node_id", `String id);
        ("services", `List svc_list);
      ])
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Handle GET /services/:name/binary - serve service binary *)
let handle_service_binary name =
  match Hashtbl.find_opt services name with
  | Some svc ->
      (match svc.binary_path with
       | Some path when Sys.file_exists path ->
           (* Serve the binary file *)
           let ic = open_in_bin path in
           let len = in_channel_length ic in
           let data = really_input_string ic len in
           close_in ic;
           let headers = Cohttp.Header.of_list [
             ("Content-Type", "application/octet-stream");
             ("Content-Disposition", Printf.sprintf "attachment; filename=\"%s\"" name);
           ] in
           Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:data ()
       | Some path ->
           respond_error 404 (Printf.sprintf "Binary not found at path: %s" path)
       | None ->
           (* Try to find binary in bundle directory *)
           let bundle_bin = Printf.sprintf "./bin/%s" name in
           if Sys.file_exists bundle_bin then begin
             let ic = open_in_bin bundle_bin in
             let len = in_channel_length ic in
             let data = really_input_string ic len in
             close_in ic;
             let headers = Cohttp.Header.of_list [
               ("Content-Type", "application/octet-stream");
               ("Content-Disposition", Printf.sprintf "attachment; filename=\"%s\"" name);
             ] in
             Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:data ()
           end else
             respond_error 404 "No binary path configured for service")
  | None ->
      respond_error 404 ("Service not found: " ^ name)

(** Handle GET /services/:name/config - serve service config *)
let handle_service_config name =
  match Hashtbl.find_opt services name with
  | Some svc ->
      respond_json ~status:`OK (service_to_json svc)
  | None ->
      respond_error 404 ("Service not found: " ^ name)

(** Handle POST /nodes/:id/service-status - update service status from node *)
let handle_service_status id body_str =
  match Hashtbl.find_opt nodes id with
  | Some node ->
      (try
        let json = Yojson.Safe.from_string body_str in
        let open Yojson.Safe.Util in
        let svc_name = json |> member "service" |> to_string in
        let status = json |> member "status" |> to_string in
        let port = json |> member "port" |> to_int in
        let ip = json |> member "ip" |> to_string in

        (* Update service with endpoint info *)
        (match Hashtbl.find_opt services svc_name with
         | Some svc ->
             let endpoint = Printf.sprintf "http://%s:%d" ip port in
             let endpoints = if List.mem endpoint svc.endpoints then svc.endpoints else endpoint :: svc.endpoints in
             let updated = { svc with
               status = if status = "running" then "running" else svc.status;
               replicas_ready = svc.replicas_ready + 1;
               endpoints;
             } in
             Hashtbl.replace services svc_name updated;
             Printf.printf "[SERVICE] %s now running on %s (node: %s)\n%!" svc_name endpoint node.hostname;

             (* Broadcast update *)
             let _ = broadcast_event "service_update" (service_to_json updated) in

             respond_json ~status:`OK (`Assoc [
               ("status", `String "ok");
               ("service", `String svc_name);
               ("endpoint", `String endpoint);
             ])
         | None ->
             respond_error 404 ("Service not found: " ^ svc_name))
      with e ->
        respond_error 400 (Printf.sprintf "Invalid JSON: %s" (Printexc.to_string e)))
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Handle GET /services *)
let handle_list_services () =
  respond_json ~status:`OK (services_to_json ())

(** Handle GET /services/:name *)
let handle_get_service name =
  match Hashtbl.find_opt services name with
  | Some svc -> respond_json ~status:`OK (service_to_json svc)
  | None -> respond_error 404 ("Service not found: " ^ name)

(** Handle POST /services - deploy a service *)
let handle_deploy_service body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in
    let name = json |> member "name" |> to_string in
    let runtime = json |> member "runtime" |> to_string_option |> Option.value ~default:"http" in
    let ports = json |> member "ports" |> to_list |> List.map to_int in
    let replicas = json |> member "replicas" |> to_int_option |> Option.value ~default:1 in
    let binary_path = json |> member "binary_path" |> to_string_option in
    let image = json |> member "image" |> to_string_option in
    let env =
      match json |> member "env" with
      | `Assoc pairs -> List.map (fun (k, v) -> (k, to_string v)) pairs
      | _ -> []
    in
    let now = Unix.gettimeofday () in
    let is_update = Hashtbl.mem services name in

    (* In a real implementation, we would actually deploy the service to k8s here *)
    let svc = {
      svc_name = name;
      runtime;
      ports;
      replicas;
      replicas_ready = 0;  (* Will be updated by actual deployment *)
      status = "deploying";
      binary_path;
      image;
      env;
      deployed_at = now;
      endpoints = [];  (* Will be populated after deployment *)
    } in

    Hashtbl.replace services name svc;
    Printf.printf "[%s] Service %s (%s): ports=%s replicas=%d\n%!"
      (if is_update then "UPDATE" else "DEPLOY")
      name runtime
      (String.concat "," (List.map string_of_int ports))
      replicas;

    (* Broadcast event to dashboard clients *)
    let event_type = if is_update then "service_updated" else "service_deployed" in
    Lwt.async (fun () -> broadcast_event event_type (service_to_json svc));

    (* Use scheduler to select nodes and push deploy commands *)
    let target_nodes = schedule_service replicas in
    if List.length target_nodes = 0 then begin
      Printf.printf "[SCHEDULER] No healthy nodes available, service pending\n%!";
      let pending_svc = { svc with status = "pending" } in
      Hashtbl.replace services name pending_svc
    end else begin
      Printf.printf "[SCHEDULER] Scheduling %s on %d node(s)\n%!" name (List.length target_nodes);
      let port = if List.length ports > 0 then List.hd ports else 8080 in
      (* Send deploy command to each selected node *)
      (* Don't send binary_path as URL - let the init script use the /services/:name/binary endpoint *)
      List.iter (fun node ->
        Lwt.async (fun () -> send_deploy_command node.id name port ())
      ) target_nodes
    end;

    respond_json ~status:(if is_update then `OK else `Created) (service_to_json svc)
  with e ->
    respond_error 400 ("Invalid service request: " ^ Printexc.to_string e)

(** Handle DELETE /services/:name *)
let handle_delete_service name =
  match Hashtbl.find_opt services name with
  | Some _svc ->
      Hashtbl.remove services name;
      Printf.printf "[DELETE] Removed service %s\n%!" name;

      (* Send stop command to all nodes *)
      let node_list = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [] in
      List.iter (fun node ->
        Lwt.async (fun () -> send_stop_command node.id name)
      ) node_list;

      (* Broadcast event to dashboard clients *)
      Lwt.async (fun () -> broadcast_event "service_removed" (`Assoc [
        ("name", `String name);
      ]));
      respond_json ~status:`OK (`Assoc [("deleted", `String name)])
  | None ->
      respond_error 404 ("Service not found: " ^ name)

(** Handle POST /constraints/check - check infrastructure constraints *)
let handle_check_constraints body_str =
  try
    let json = Yojson.Safe.from_string body_str in
    let open Yojson.Safe.Util in

    (* Extract constraints *)
    let cluster = json |> member "cluster" in
    let min_nodes = cluster |> member "min_nodes" |> to_int_option |> Option.value ~default:1 in
    let min_control_planes = cluster |> member "min_control_planes" |> to_int_option |> Option.value ~default:1 in

    let node_requirements = json |> member "node_requirements" in
    let min_cpus = node_requirements |> member "min_cpus" |> to_int_option |> Option.value ~default:1 in
    let min_memory_mb = node_requirements |> member "min_memory_mb" |> to_int_option |> Option.value ~default:512 in
    let min_disk_gb = node_requirements |> member "min_disk_gb" |> to_int_option |> Option.value ~default:10 in

    (* Check current infrastructure *)
    let node_list = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [] in
    let num_nodes = List.length node_list in
    let control_planes = List.filter (fun n ->
      let role = List.assoc_opt "role" n.metadata |> Option.value ~default:"worker" in
      role = "control-plane" || role = "master"
    ) node_list in
    let num_control_planes = List.length control_planes in

    (* Check node resources *)
    let nodes_with_resources = List.filter (fun n ->
      n.cpus >= min_cpus && n.memory_mb >= min_memory_mb && n.disk_gb >= min_disk_gb
    ) node_list in

    (* Build result *)
    let issues = ref [] in

    if num_nodes < min_nodes then
      issues := Printf.sprintf "Not enough nodes: have %d, need %d" num_nodes min_nodes :: !issues;

    if num_control_planes < min_control_planes then
      issues := Printf.sprintf "Not enough control planes: have %d, need %d" num_control_planes min_control_planes :: !issues;

    if List.length nodes_with_resources < min_nodes then
      issues := Printf.sprintf "Only %d nodes meet resource requirements (cpus>=%d, memory>=%dMB, disk>=%dGB)"
        (List.length nodes_with_resources) min_cpus min_memory_mb min_disk_gb :: !issues;

    let satisfied = List.length !issues = 0 in

    Printf.printf "[CONSTRAINTS] Check: satisfied=%b (nodes=%d/%d, cp=%d/%d)\n%!"
      satisfied num_nodes min_nodes num_control_planes min_control_planes;

    respond_json ~status:`OK (`Assoc [
      ("satisfied", `Bool satisfied);
      ("issues", `List (List.map (fun i -> `String i) !issues));
      ("current", `Assoc [
        ("nodes", `Int num_nodes);
        ("control_planes", `Int num_control_planes);
        ("nodes_meeting_requirements", `Int (List.length nodes_with_resources));
      ]);
      ("required", `Assoc [
        ("min_nodes", `Int min_nodes);
        ("min_control_planes", `Int min_control_planes);
        ("min_cpus", `Int min_cpus);
        ("min_memory_mb", `Int min_memory_mb);
        ("min_disk_gb", `Int min_disk_gb);
      ]);
    ])
  with e ->
    respond_error 400 ("Invalid constraints: " ^ Printexc.to_string e)

(** Get full state for dashboard *)
let handle_api_state () =
  let node_list = Hashtbl.fold (fun _ node acc -> node :: acc) nodes [] in
  let svc_list = Hashtbl.fold (fun _ svc acc -> svc :: acc) services [] in
  respond_json ~status:`OK (`Assoc [
    ("timestamp", `Float (Unix.gettimeofday ()));
    ("nodes", `List (List.map node_to_json node_list));
    ("services", `List (List.map service_to_json svc_list));
    ("config", `Assoc [
      ("k3s_url", `String !k3s_url);
      ("image_url", `String !image_url);
    ]);
  ])

(** SSE events handler *)
let handle_events () =
  let stream, push = Lwt_stream.create () in
  let push_fn msg = push (Some msg) in

  (* Register client *)
  Lwt.async (fun () ->
    Lwt_mutex.with_lock sse_mutex (fun () ->
      sse_clients := push_fn :: !sse_clients;
      Printf.printf "[SSE] Client connected (%d total)\n%!" (List.length !sse_clients);
      Lwt.return_unit
    )
  );

  (* Send initial state *)
  let init_msg = Printf.sprintf "event: init\ndata: %s\n\n"
    (Yojson.Safe.to_string (`Assoc [
      ("nodes", `Int (Hashtbl.length nodes));
      ("services", `Int (Hashtbl.length services));
    ])) in
  push (Some init_msg);

  let headers = Cohttp.Header.of_list [
    ("Content-Type", "text/event-stream");
    ("Cache-Control", "no-cache");
    ("Connection", "keep-alive");
    ("Access-Control-Allow-Origin", "*");
  ] in
  let body = Cohttp_lwt.Body.of_stream stream in
  Cohttp_lwt_unix.Server.respond ~status:`OK ~headers ~body ()

(** Dashboard HTML *)
let dashboard_html = {|<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>SIESTE Infrastructure Dashboard</title>
    <style>
        :root {
            --bg-primary: #0d1117;
            --bg-secondary: #161b22;
            --bg-tertiary: #21262d;
            --text-primary: #c9d1d9;
            --text-secondary: #8b949e;
            --accent-blue: #58a6ff;
            --accent-green: #3fb950;
            --accent-yellow: #d29922;
            --accent-red: #f85149;
            --accent-purple: #a371f7;
            --border-color: #30363d;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg-primary);
            color: var(--text-primary);
            min-height: 100vh;
        }
        .header {
            background: var(--bg-secondary);
            border-bottom: 1px solid var(--border-color);
            padding: 1rem 2rem;
            display: flex;
            align-items: center;
            justify-content: space-between;
        }
        .header h1 {
            font-size: 1.5rem;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }
        .header h1::before {
            content: "☁️";
        }
        .status-badge {
            padding: 0.25rem 0.75rem;
            border-radius: 1rem;
            font-size: 0.75rem;
            font-weight: 600;
        }
        .status-connected { background: var(--accent-green); color: #000; }
        .status-disconnected { background: var(--accent-red); color: #fff; }
        .container {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
            gap: 1.5rem;
            padding: 1.5rem;
            max-width: 1800px;
            margin: 0 auto;
        }
        .card {
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 0.5rem;
            overflow: hidden;
        }
        .card-header {
            background: var(--bg-tertiary);
            padding: 0.75rem 1rem;
            border-bottom: 1px solid var(--border-color);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .card-header h2 {
            font-size: 0.875rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--text-secondary);
        }
        .card-body {
            padding: 1rem;
            max-height: 400px;
            overflow-y: auto;
        }
        .metric {
            display: flex;
            justify-content: space-between;
            padding: 0.5rem 0;
            border-bottom: 1px solid var(--border-color);
        }
        .metric:last-child { border-bottom: none; }
        .metric-label { color: var(--text-secondary); }
        .metric-value { font-weight: 600; font-family: monospace; }
        .node-item, .service-item {
            background: var(--bg-tertiary);
            border-radius: 0.375rem;
            padding: 0.75rem;
            margin-bottom: 0.5rem;
        }
        .node-item:last-child, .service-item:last-child { margin-bottom: 0; }
        .item-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 0.5rem;
        }
        .item-name {
            font-weight: 600;
            color: var(--accent-blue);
        }
        .item-status {
            padding: 0.125rem 0.5rem;
            border-radius: 0.25rem;
            font-size: 0.75rem;
            font-weight: 500;
        }
        .status-running { background: rgba(63, 185, 80, 0.2); color: var(--accent-green); }
        .status-deploying { background: rgba(210, 153, 34, 0.2); color: var(--accent-yellow); }
        .status-pending { background: rgba(139, 148, 158, 0.2); color: var(--text-secondary); }
        .status-failed { background: rgba(248, 81, 73, 0.2); color: var(--accent-red); }
        .item-details {
            font-size: 0.8125rem;
            color: var(--text-secondary);
            display: grid;
            grid-template-columns: repeat(2, 1fr);
            gap: 0.25rem;
        }
        .empty-state {
            text-align: center;
            padding: 2rem;
            color: var(--text-secondary);
        }
        .event-log {
            font-family: monospace;
            font-size: 0.75rem;
        }
        .event-item {
            padding: 0.375rem 0;
            border-bottom: 1px solid var(--border-color);
            display: flex;
            gap: 0.5rem;
        }
        .event-time {
            color: var(--text-secondary);
            white-space: nowrap;
        }
        .event-type {
            font-weight: 600;
            white-space: nowrap;
        }
        .event-node { color: var(--accent-blue); }
        .event-service { color: var(--accent-purple); }
        .event-message { color: var(--text-primary); }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        .loading { animation: pulse 1.5s infinite; }
    </style>
</head>
<body>
    <header class="header">
        <h1>SIESTE Infrastructure Dashboard</h1>
        <span id="connection-status" class="status-badge status-disconnected">Disconnected</span>
    </header>
    <div class="container">
        <div class="card">
            <div class="card-header">
                <h2>📊 Overview</h2>
            </div>
            <div class="card-body">
                <div class="metric">
                    <span class="metric-label">Nodes</span>
                    <span class="metric-value" id="node-count">0</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Services</span>
                    <span class="metric-value" id="service-count">0</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Running Services</span>
                    <span class="metric-value" id="running-count">0</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Total CPUs</span>
                    <span class="metric-value" id="total-cpus">0</span>
                </div>
                <div class="metric">
                    <span class="metric-label">Total Memory</span>
                    <span class="metric-value" id="total-memory">0 GB</span>
                </div>
            </div>
        </div>
        <div class="card">
            <div class="card-header">
                <h2>🖥️ Nodes</h2>
                <span id="node-badge">0</span>
            </div>
            <div class="card-body" id="nodes-container">
                <div class="empty-state loading">Loading nodes...</div>
            </div>
        </div>
        <div class="card">
            <div class="card-header">
                <h2>📦 Services</h2>
                <span id="service-badge">0</span>
            </div>
            <div class="card-body" id="services-container">
                <div class="empty-state loading">Loading services...</div>
            </div>
        </div>
        <div class="card">
            <div class="card-header">
                <h2>📜 Event Log</h2>
            </div>
            <div class="card-body event-log" id="event-log">
                <div class="empty-state">Waiting for events...</div>
            </div>
        </div>
    </div>
    <script>
        let state = { nodes: [], services: [] };
        let eventSource = null;

        function formatTime(ts) {
            const d = new Date(ts * 1000);
            return d.toLocaleTimeString();
        }

        function formatBytes(mb) {
            if (mb >= 1024) return (mb / 1024).toFixed(1) + ' GB';
            return mb + ' MB';
        }

        function renderNodes() {
            const container = document.getElementById('nodes-container');
            if (state.nodes.length === 0) {
                container.innerHTML = '<div class="empty-state">No nodes registered</div>';
                return;
            }
            container.innerHTML = state.nodes.map(n => `
                <div class="node-item">
                    <div class="item-header">
                        <span class="item-name">${n.hostname}</span>
                        <span class="item-status status-running">${n.id}</span>
                    </div>
                    <div class="item-details">
                        <span>IP: ${n.ip_address}</span>
                        <span>MAC: ${n.mac_address}</span>
                        <span>CPUs: ${n.cpus}</span>
                        <span>Memory: ${formatBytes(n.memory_mb)}</span>
                        <span>Disk: ${n.disk_gb} GB</span>
                        <span>Registered: ${formatTime(n.registered_at)}</span>
                    </div>
                </div>
            `).join('');
        }

        function renderServices() {
            const container = document.getElementById('services-container');
            if (state.services.length === 0) {
                container.innerHTML = '<div class="empty-state">No services deployed</div>';
                return;
            }
            container.innerHTML = state.services.map(s => `
                <div class="service-item">
                    <div class="item-header">
                        <span class="item-name">${s.name}</span>
                        <span class="item-status status-${s.status}">${s.status}</span>
                    </div>
                    <div class="item-details">
                        <span>Runtime: ${s.runtime}</span>
                        <span>Replicas: ${s.replicas_ready}/${s.replicas}</span>
                        <span>Ports: ${s.ports.join(', ') || 'none'}</span>
                        <span>Deployed: ${formatTime(s.deployed_at)}</span>
                    </div>
                </div>
            `).join('');
        }

        function updateMetrics() {
            document.getElementById('node-count').textContent = state.nodes.length;
            document.getElementById('node-badge').textContent = state.nodes.length;
            document.getElementById('service-count').textContent = state.services.length;
            document.getElementById('service-badge').textContent = state.services.length;
            document.getElementById('running-count').textContent =
                state.services.filter(s => s.status === 'running').length;
            document.getElementById('total-cpus').textContent =
                state.nodes.reduce((acc, n) => acc + n.cpus, 0);
            const totalMem = state.nodes.reduce((acc, n) => acc + n.memory_mb, 0);
            document.getElementById('total-memory').textContent = formatBytes(totalMem);
        }

        function addEvent(type, message) {
            const log = document.getElementById('event-log');
            const empty = log.querySelector('.empty-state');
            if (empty) empty.remove();

            const time = new Date().toLocaleTimeString();
            const typeClass = type.includes('node') ? 'event-node' : 'event-service';
            const item = document.createElement('div');
            item.className = 'event-item';
            item.innerHTML = `
                <span class="event-time">${time}</span>
                <span class="event-type ${typeClass}">${type}</span>
                <span class="event-message">${message}</span>
            `;
            log.insertBefore(item, log.firstChild);
            // Keep only last 50 events
            while (log.children.length > 50) {
                log.removeChild(log.lastChild);
            }
        }

        function fetchState() {
            fetch('/api/state')
                .then(r => r.json())
                .then(data => {
                    state.nodes = data.nodes || [];
                    state.services = data.services || [];
                    renderNodes();
                    renderServices();
                    updateMetrics();
                })
                .catch(err => console.error('Failed to fetch state:', err));
        }

        function connectSSE() {
            if (eventSource) eventSource.close();

            eventSource = new EventSource('/events');
            const status = document.getElementById('connection-status');

            eventSource.onopen = () => {
                status.textContent = 'Connected';
                status.className = 'status-badge status-connected';
                addEvent('system', 'Connected to server');
            };

            eventSource.onerror = () => {
                status.textContent = 'Disconnected';
                status.className = 'status-badge status-disconnected';
                setTimeout(connectSSE, 3000);
            };

            eventSource.addEventListener('init', (e) => {
                const data = JSON.parse(e.data);
                addEvent('system', `Server has ${data.nodes} nodes, ${data.services} services`);
                fetchState();
            });

            eventSource.addEventListener('node_added', (e) => {
                const node = JSON.parse(e.data);
                state.nodes = state.nodes.filter(n => n.id !== node.id);
                state.nodes.push(node);
                renderNodes();
                updateMetrics();
                addEvent('node_added', `${node.hostname} (${node.ip_address})`);
            });

            eventSource.addEventListener('node_updated', (e) => {
                const node = JSON.parse(e.data);
                state.nodes = state.nodes.map(n => n.id === node.id ? node : n);
                renderNodes();
                updateMetrics();
                addEvent('node_updated', `${node.hostname} updated`);
            });

            eventSource.addEventListener('node_removed', (e) => {
                const data = JSON.parse(e.data);
                state.nodes = state.nodes.filter(n => n.id !== data.id);
                renderNodes();
                updateMetrics();
                addEvent('node_removed', data.hostname || data.id);
            });

            eventSource.addEventListener('service_deployed', (e) => {
                const svc = JSON.parse(e.data);
                state.services = state.services.filter(s => s.name !== svc.name);
                state.services.push(svc);
                renderServices();
                updateMetrics();
                addEvent('service_deployed', `${svc.name} (${svc.runtime})`);
            });

            eventSource.addEventListener('service_updated', (e) => {
                const svc = JSON.parse(e.data);
                state.services = state.services.map(s => s.name === svc.name ? svc : s);
                renderServices();
                updateMetrics();
                addEvent('service_updated', `${svc.name} -> ${svc.status}`);
            });

            eventSource.addEventListener('service_ready', (e) => {
                const svc = JSON.parse(e.data);
                state.services = state.services.map(s => s.name === svc.name ? svc : s);
                renderServices();
                updateMetrics();
                addEvent('service_ready', `${svc.name} is now running`);
            });

            eventSource.addEventListener('service_removed', (e) => {
                const data = JSON.parse(e.data);
                state.services = state.services.filter(s => s.name !== data.name);
                renderServices();
                updateMetrics();
                addEvent('service_removed', data.name);
            });
        }

        // Initial load
        fetchState();
        connectSSE();

        // Periodic refresh as backup
        setInterval(fetchState, 30000);
    </script>
</body>
</html>
|}

(** Serve dashboard *)
let handle_dashboard () =
  let headers = Cohttp.Header.of_list [
    ("Content-Type", "text/html; charset=utf-8");
  ] in
  Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:dashboard_html ()

(** List available OS images *)
let handle_list_images () =
  let dir = !images_dir in
  let images =
    try
      let entries = Sys.readdir dir in
      Array.to_list entries
      |> List.filter (fun f ->
          Filename.check_suffix f ".img" ||
          Filename.check_suffix f ".img.gz" ||
          Filename.check_suffix f ".qcow2")
      |> List.map (fun name ->
          let path = Filename.concat dir name in
          let stats = Unix.stat path in
          let size_mb = stats.Unix.st_size / (1024 * 1024) in
          `Assoc [
            ("name", `String name);
            ("size_mb", `Int size_mb);
            ("path", `String path);
          ])
    with _ -> []
  in
  respond_json ~status:`OK (`Assoc [
    ("images_dir", `String dir);
    ("default_image", `String !image_url);
    ("count", `Int (List.length images));
    ("images", `List images);
  ])

(** Serve an OS image file *)
let handle_serve_image filename =
  let path = Filename.concat !images_dir filename in
  (* Security: ensure path doesn't escape images_dir *)
  let canonical_dir = Unix.realpath !images_dir in
  let canonical_path =
    try Unix.realpath path
    with Unix.Unix_error _ -> ""
  in
  if not (String.length canonical_path > 0 &&
          String.sub canonical_path 0 (String.length canonical_dir) = canonical_dir) then
    respond_error 403 "Access denied: path traversal attempt"
  else if not (Sys.file_exists path) then
    respond_error 404 ("Image not found: " ^ filename)
  else begin
    (* Determine content type *)
    let content_type =
      if Filename.check_suffix filename ".gz" then "application/gzip"
      else if Filename.check_suffix filename ".qcow2" then "application/octet-stream"
      else "application/octet-stream"
    in
    let stats = Unix.stat path in
    let headers = Cohttp.Header.of_list [
      ("Content-Type", content_type);
      ("Content-Length", string_of_int stats.Unix.st_size);
      ("Content-Disposition", Printf.sprintf "attachment; filename=\"%s\"" filename);
    ] in
    (* Stream file content *)
    let stream =
      let ic = open_in_bin path in
      let buf_size = 64 * 1024 in (* 64KB chunks *)
      let buf = Bytes.create buf_size in
      Lwt_stream.from (fun () ->
        Lwt.return (
          try
            let n = input ic buf 0 buf_size in
            if n = 0 then begin
              close_in ic;
              None
            end else
              Some (Bytes.sub_string buf 0 n)
          with End_of_file ->
            close_in ic;
            None
        )
      )
    in
    let body = Cohttp_lwt.Body.of_stream stream in
    Cohttp_lwt_unix.Server.respond ~status:`OK ~headers ~body ()
  end

(** Extract client IP from connection *)
(* ============================================================ *)
(* Provisioning profiles (poussés par hamac, servis aux PXE)     *)
(* ============================================================ *)

let provisioning_record_to_json (r : provisioning_record) : Yojson.Safe.t =
  `Assoc [
    "profile_name", `String r.pr_profile_name;
    "cloud_init", `String r.pr_cloud_init;
    "ipxe_script", `String r.pr_ipxe_script;
    "os_image_url", `String r.pr_os_image_url;
    "os_image_sha256", `String r.pr_os_image_sha256;
    "os_format", `String r.pr_os_format;
    "created_at", `Float r.pr_created_at;
  ]

let provisioning_record_of_json (j : Yojson.Safe.t)
  : (provisioning_record, string) Stdlib.result =
  match j with
  | `Assoc fields ->
    let get_str k = match List.assoc_opt k fields with
      | Some (`String s) -> Ok s
      | Some _ -> Error (Printf.sprintf "field '%s' must be a string" k)
      | None -> Error (Printf.sprintf "missing field '%s'" k)
    in
    let get_str_or_default k d = match List.assoc_opt k fields with
      | Some (`String s) -> Ok s
      | None -> Ok d
      | _ -> Error (Printf.sprintf "field '%s' must be a string" k)
    in
    let get_float k = match List.assoc_opt k fields with
      | Some (`Float f) -> Ok f
      | Some (`Int i) -> Ok (float_of_int i)
      | None -> Ok (Unix.gettimeofday ())
      | _ -> Error (Printf.sprintf "field '%s' must be a number" k)
    in
    (match get_str "profile_name" with
     | Error e -> Error e
     | Ok pr_profile_name ->
       match get_str "cloud_init" with
       | Error e -> Error e
       | Ok pr_cloud_init ->
         match get_str_or_default "ipxe_script" "" with
         | Error e -> Error e
         | Ok pr_ipxe_script ->
           match get_str_or_default "os_image_url" "" with
           | Error e -> Error e
           | Ok pr_os_image_url ->
             match get_str_or_default "os_image_sha256" "" with
             | Error e -> Error e
             | Ok pr_os_image_sha256 ->
               match get_str_or_default "os_format" "" with
               | Error e -> Error e
               | Ok pr_os_format ->
                 match get_float "created_at" with
                 | Error e -> Error e
                 | Ok pr_created_at ->
                   Ok { pr_profile_name; pr_cloud_init; pr_ipxe_script;
                        pr_os_image_url; pr_os_image_sha256; pr_os_format;
                        pr_created_at })
  | _ -> Error "expected a JSON object"

(** Persiste un record sur disque dans state_dir/provisioning/<mac>.json *)
let save_provisioning_to_disk (mac : string) (r : provisioning_record) : unit =
  let dir = provisioning_dir () in
  (try Unix.mkdir state_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (mac ^ ".json") in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string (provisioning_record_to_json r));
  close_out oc

let delete_provisioning_from_disk (mac : string) : unit =
  let path = Filename.concat (provisioning_dir ()) (mac ^ ".json") in
  try Unix.unlink path
  with Unix.Unix_error (Unix.ENOENT, _, _) -> ()

(** Charge tous les profils au démarrage. *)
let load_provisioning_from_disk () : unit =
  let dir = provisioning_dir () in
  if Sys.file_exists dir && Sys.is_directory dir then begin
    let files = Sys.readdir dir in
    Array.iter (fun fname ->
      if Filename.check_suffix fname ".json" then begin
        let mac = Filename.chop_suffix fname ".json" in
        let path = Filename.concat dir fname in
        try
          let ic = open_in path in
          let n = in_channel_length ic in
          let s = really_input_string ic n in
          close_in ic;
          match Yojson.Safe.from_string s |> provisioning_record_of_json with
          | Ok r -> Hashtbl.replace provisioning mac r
          | Error msg ->
            Printf.eprintf "[provisioning] skip %s: %s\n" path msg
        with e ->
          Printf.eprintf "[provisioning] error loading %s: %s\n"
            path (Printexc.to_string e)
      end
    ) files
  end

let handle_provisioning_push mac body_str =
  let mac = normalize_mac mac in
  match (try Ok (Yojson.Safe.from_string body_str)
         with e -> Error (Printexc.to_string e)) with
  | Error e -> respond_error 400 ("Invalid JSON: " ^ e)
  | Ok j ->
    (* On accepte un objet sans created_at en entrée — on l'ajoute. *)
    let with_ts = match j with
      | `Assoc fields when not (List.mem_assoc "created_at" fields) ->
        `Assoc (("created_at", `Float (Unix.gettimeofday ())) :: fields)
      | _ -> j
    in
    match provisioning_record_of_json with_ts with
    | Error msg -> respond_error 400 msg
    | Ok r ->
      Hashtbl.replace provisioning mac r;
      save_provisioning_to_disk mac r;
      Lwt.async (fun () ->
        broadcast_event "provisioning-updated"
          (`Assoc ["mac", `String mac;
                   "profile_name", `String r.pr_profile_name]));
      respond_json ~status:`Created
        (`Assoc ["status", `String "ok";
                 "mac", `String mac;
                 "profile_name", `String r.pr_profile_name])

let handle_provisioning_get mac =
  let mac = normalize_mac mac in
  match Hashtbl.find_opt provisioning mac with
  | None -> respond_error 404 ("No provisioning record for " ^ mac)
  | Some r ->
    respond_json ~status:`OK (provisioning_record_to_json r)

let handle_provisioning_get_cloud_init mac =
  let mac = normalize_mac mac in
  match Hashtbl.find_opt provisioning mac with
  | None -> respond_error 404 ("No provisioning record for " ^ mac)
  | Some r ->
    let headers = Cohttp.Header.of_list [
      ("Content-Type", "text/yaml; charset=utf-8")
    ] in
    Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers
      ~body:r.pr_cloud_init ()

let handle_provisioning_get_ipxe mac =
  let mac = normalize_mac mac in
  match Hashtbl.find_opt provisioning mac with
  | None -> respond_error 404 ("No provisioning record for " ^ mac)
  | Some r ->
    let headers = Cohttp.Header.of_list [
      ("Content-Type", "text/plain; charset=utf-8")
    ] in
    Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers
      ~body:r.pr_ipxe_script ()

let handle_provisioning_delete mac =
  let mac = normalize_mac mac in
  if Hashtbl.mem provisioning mac then begin
    Hashtbl.remove provisioning mac;
    delete_provisioning_from_disk mac;
    Lwt.async (fun () ->
      broadcast_event "provisioning-deleted"
        (`Assoc ["mac", `String mac]));
    respond_json ~status:`OK
      (`Assoc ["status", `String "deleted"; "mac", `String mac])
  end else
    respond_error 404 ("No provisioning record for " ^ mac)

let handle_provisioning_list () =
  let entries = Hashtbl.fold (fun mac r acc ->
    `Assoc [
      "mac", `String mac;
      "profile_name", `String r.pr_profile_name;
      "os_image_url", `String r.pr_os_image_url;
      "created_at", `Float r.pr_created_at;
    ] :: acc
  ) provisioning [] in
  respond_json ~status:`OK (`Assoc ["provisioning", `List entries])

(* ============================================================ *)
(* Allowed MACs (administrés via API/UI, propagés à dnsmasq)     *)
(* ============================================================ *)

let allowed_mac_entry_to_json (e : allowed_mac_entry) : Yojson.Safe.t =
  `Assoc [
    "mac", `String e.am_mac;
    "label", `String e.am_label;
    "added_by", `String e.am_added_by;
    "added_at", `Float e.am_added_at;
  ]

let allowed_mac_entry_of_json (j : Yojson.Safe.t)
  : (allowed_mac_entry, string) Stdlib.result =
  match j with
  | `Assoc fields ->
    let get_str ?(default="") k = match List.assoc_opt k fields with
      | Some (`String s) -> Ok s
      | None -> Ok default
      | _ -> Error (Printf.sprintf "field '%s' must be a string" k)
    in
    (match get_str "mac" with
     | Error e -> Error e
     | Ok mac when mac = "" -> Error "field 'mac' is required and must be non-empty"
     | Ok mac ->
       match get_str ~default:"" "label" with
       | Error e -> Error e
       | Ok label ->
         match get_str ~default:"unknown" "added_by" with
         | Error e -> Error e
         | Ok added_by ->
           let added_at = match List.assoc_opt "added_at" fields with
             | Some (`Float f) -> f
             | Some (`Int i) -> float_of_int i
             | _ -> Unix.gettimeofday ()
           in
           Ok {
             am_mac = normalize_mac mac;
             am_label = label;
             am_added_by = added_by;
             am_added_at = added_at;
           })
  | _ -> Error "expected a JSON object"

let save_allowed_macs_to_disk () : unit =
  (try Unix.mkdir state_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let entries = Hashtbl.fold (fun _ e acc -> allowed_mac_entry_to_json e :: acc)
                  allowed_macs [] in
  let json : Yojson.Safe.t = `List entries in
  let path = allowed_macs_file () in
  let tmp = path ^ ".tmp" in
  let oc = open_out tmp in
  output_string oc (Yojson.Safe.to_string json);
  close_out oc;
  Sys.rename tmp path

let load_allowed_macs_from_disk () : unit =
  let path = allowed_macs_file () in
  if Sys.file_exists path then
    try
      let ic = open_in path in
      let n = in_channel_length ic in
      let s = really_input_string ic n in
      close_in ic;
      match Yojson.Safe.from_string s with
      | `List items ->
        List.iter (fun j ->
          match allowed_mac_entry_of_json j with
          | Ok e -> Hashtbl.replace allowed_macs e.am_mac e
          | Error msg ->
            Printf.eprintf "[allowed-macs] skip invalid entry: %s\n" msg
        ) items
      | _ ->
        Printf.eprintf "[allowed-macs] %s : expected a JSON list, ignored\n" path
    with e ->
      Printf.eprintf "[allowed-macs] error loading %s: %s\n"
        path (Printexc.to_string e)

let handle_allowed_macs_list () =
  let entries = Hashtbl.fold (fun _ e acc -> allowed_mac_entry_to_json e :: acc)
                  allowed_macs [] in
  respond_json ~status:`OK (`Assoc ["allowed_macs", `List entries])

let handle_allowed_macs_add ?(added_by="unknown") body_str =
  match (try Ok (Yojson.Safe.from_string body_str)
         with e -> Error (Printexc.to_string e)) with
  | Error e -> respond_error 400 ("Invalid JSON: " ^ e)
  | Ok j ->
    (* Force added_by + added_at à des valeurs serveur, ignorer celles du client. *)
    let j_normalized = match j with
      | `Assoc fields ->
        let cleaned = List.filter (fun (k, _) ->
          k <> "added_by" && k <> "added_at") fields in
        `Assoc (("added_by", `String added_by) ::
                ("added_at", `Float (Unix.gettimeofday ())) ::
                cleaned)
      | _ -> j
    in
    match allowed_mac_entry_of_json j_normalized with
    | Error msg -> respond_error 400 msg
    | Ok e ->
      let was_present = Hashtbl.mem allowed_macs e.am_mac in
      Hashtbl.replace allowed_macs e.am_mac e;
      save_allowed_macs_to_disk ();
      Lwt.async (fun () ->
        broadcast_event "allowed-mac-updated"
          (`Assoc ["mac", `String e.am_mac;
                   "label", `String e.am_label;
                   "added_by", `String e.am_added_by]));
      let status = if was_present then `OK else `Created in
      respond_json ~status (allowed_mac_entry_to_json e)

let handle_allowed_macs_delete mac =
  let mac = normalize_mac mac in
  if Hashtbl.mem allowed_macs mac then begin
    Hashtbl.remove allowed_macs mac;
    save_allowed_macs_to_disk ();
    Lwt.async (fun () ->
      broadcast_event "allowed-mac-deleted"
        (`Assoc ["mac", `String mac]));
    respond_json ~status:`OK
      (`Assoc ["status", `String "deleted"; "mac", `String mac])
  end else
    respond_error 404 ("No allowed MAC entry for " ^ mac)

(** Format dnsmasq dhcp-hostsfile : une ligne par MAC autorisée.
    dnsmasq lit ce fichier au démarrage et le relit sur SIGHUP. *)
let handle_allowed_macs_dnsmasq_hostsfile () =
  let lines = Hashtbl.fold (fun mac _ acc ->
    Printf.sprintf "%s,set:hamac-pxe" mac :: acc
  ) allowed_macs [] in
  let body = String.concat "\n" lines ^ (if lines = [] then "" else "\n") in
  let headers = Cohttp.Header.of_list [
    ("Content-Type", "text/plain; charset=utf-8")
  ] in
  Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body ()

(* ============================================================ *)
(* Catalogue de profils + modèle Machine (mode b, IT)           *)
(* ============================================================ *)

module MT = Hamac_provisioning.Manifest_types

(** Conversion Yojson (params venant de l'API REST) → Yaml.value
    (format attendu par provisioning_gen). *)
let rec yojson_to_yaml (j : Yojson.Safe.t) : Yaml.value =
  match j with
  | `Null -> `Null
  | `Bool b -> `Bool b
  | `Int i -> `Float (float_of_int i)
  | `Intlit s -> `String s
  | `Float f -> `Float f
  | `String s -> `String s
  | `List l | `Tuple l -> `A (List.map yojson_to_yaml l)
  | `Assoc a -> `O (List.map (fun (k, v) -> (k, yojson_to_yaml v)) a)
  | `Variant (n, _) -> `String n

(** Charge les profils d'un répertoire : les .yaml → provisioning_profile_manifest. *)
let load_profiles_from_dir (dir : string)
  : (string * MT.provisioning_profile_manifest) list =
  if Sys.file_exists dir && Sys.is_directory dir then
    Sys.readdir dir |> Array.to_list
    |> List.filter (fun f ->
         Filename.check_suffix f ".yaml" || Filename.check_suffix f ".yml")
    |> List.filter_map (fun f ->
         let path = Fpath.v (Filename.concat dir f) in
         match Hamac_provisioning.Manifest_parser.load_file path with
         | Ok (MT.MProvisioningProfile p, _) -> Some (p.MT.pp_name, p)
         | _ -> None)
  else []

(** Catalogue effectif : built-in ∪ custom (custom prioritaire à nom égal). *)
let catalog () : (string * MT.provisioning_profile_manifest) list =
  let tbl : (string, MT.provisioning_profile_manifest) Hashtbl.t = Hashtbl.create 16 in
  List.iter (fun (n, p) -> Hashtbl.replace tbl n p)
    (load_profiles_from_dir builtin_profiles_dir);
  List.iter (fun (n, p) -> Hashtbl.replace tbl n p)
    (load_profiles_from_dir (custom_profiles_dir ()));
  Hashtbl.fold (fun n p acc -> (n, p) :: acc) tbl []

let find_profile (name : string) : MT.provisioning_profile_manifest option =
  List.assoc_opt name (catalog ())

(** Params requis agrégés d'un profil = union (par nom) des params de ses
    bundles, lus depuis leur bundle.yaml. *)
let profile_required_params (p : MT.provisioning_profile_manifest)
  : MT.bundle_param_spec list =
  List.concat_map (fun (br : MT.bundle_ref) ->
    let bpath = Fpath.v
      (Filename.concat (Filename.concat bundles_dir br.MT.bundle_name) "bundle.yaml") in
    match Hamac_provisioning.Manifest_parser.load_file bpath with
    | Ok (MT.MBundle b, _) -> b.MT.bdl_params
    | _ -> []
  ) p.MT.pp_bundles
  |> List.fold_left (fun acc (s : MT.bundle_param_spec) ->
       if List.exists (fun (x : MT.bundle_param_spec) ->
            x.MT.param_name = s.MT.param_name) acc
       then acc else acc @ [s]) []

let profile_to_json (name : string) (p : MT.provisioning_profile_manifest)
  : Yojson.Safe.t =
  let params = profile_required_params p
    |> List.map (fun (s : MT.bundle_param_spec) ->
         `Assoc [
           "name", `String s.MT.param_name;
           "type", `String s.MT.param_type;
           "required", `Bool s.MT.param_required;
         ]) in
  `Assoc [
    "name", `String name;
    "os_image", `String p.MT.pp_os.MT.os_image_name;
    "os_family", `String p.MT.pp_os.MT.os_family;
    "bundles", `List (List.map (fun (br : MT.bundle_ref) ->
                        `String br.MT.bundle_name) p.MT.pp_bundles);
    "required_params", `List params;
  ]

(* ---- Machines : JSON + persistance ---- *)

let machine_to_json (m : machine) : Yojson.Safe.t =
  `Assoc [
    "mac", `String m.mc_mac;
    "profile_name", `String m.mc_profile_name;
    "params", `Assoc m.mc_params;
    "status", `String m.mc_status;
    "created_at", `Float m.mc_created_at;
    "updated_at", `Float m.mc_updated_at;
  ]

let machine_of_json (j : Yojson.Safe.t) : (machine, string) Stdlib.result =
  match j with
  | `Assoc fields ->
    let get k = List.assoc_opt k fields in
    (match get "mac", get "profile_name" with
     | Some (`String mac), Some (`String profile_name) when mac <> "" ->
       let mc_params = match get "params" with
         | Some (`Assoc kv) -> kv
         | _ -> [] in
       let fnum k d = match get k with
         | Some (`Float f) -> f | Some (`Int i) -> float_of_int i | _ -> d in
       let now = Unix.gettimeofday () in
       Ok {
         mc_mac = normalize_mac mac;
         mc_profile_name = profile_name;
         mc_params;
         mc_status = (match get "status" with Some (`String s) -> s | _ -> "pending");
         mc_created_at = fnum "created_at" now;
         mc_updated_at = fnum "updated_at" now;
       }
     | _ -> Error "fields 'mac' and 'profile_name' are required")
  | _ -> Error "expected a JSON object"

let save_machine_to_disk (m : machine) : unit =
  let dir = machines_dir () in
  (try Unix.mkdir state_dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  let path = Filename.concat dir (m.mc_mac ^ ".json") in
  let oc = open_out path in
  output_string oc (Yojson.Safe.to_string (machine_to_json m));
  close_out oc

let delete_machine_from_disk (mac : string) : unit =
  (try Unix.unlink (Filename.concat (machines_dir ()) (mac ^ ".json"))
   with Unix.Unix_error (Unix.ENOENT, _, _) -> ())

let load_machines_from_disk () : unit =
  let dir = machines_dir () in
  if Sys.file_exists dir && Sys.is_directory dir then
    Array.iter (fun fname ->
      if Filename.check_suffix fname ".json" then
        let path = Filename.concat dir fname in
        try
          let ic = open_in path in
          let s = really_input_string ic (in_channel_length ic) in
          close_in ic;
          match machine_of_json (Yojson.Safe.from_string s) with
          | Ok m -> Hashtbl.replace machines m.mc_mac m
          | Error e -> Printf.eprintf "[machines] skip %s: %s\n" path e
        with e ->
          Printf.eprintf "[machines] error loading %s: %s\n" path (Printexc.to_string e)
    ) (Sys.readdir dir)

(** Construit le provisioning_profile_manifest effectif pour une machine :
    profil catalogue + params machine injectés dans chaque bundle_ref
    (les params machine surchargent ceux du profil). *)
let build_manifest_for_machine
    (profile : MT.provisioning_profile_manifest) (m : machine)
  : MT.provisioning_profile_manifest =
  let machine_params = List.map (fun (k, v) -> (k, yojson_to_yaml v)) m.mc_params in
  let merged_bundles = List.map (fun (br : MT.bundle_ref) ->
    let from_profile = List.filter (fun (k, _) ->
      not (List.mem_assoc k machine_params)) br.MT.bundle_params in
    { br with MT.bundle_params = machine_params @ from_profile }
  ) profile.MT.pp_bundles in
  { profile with MT.pp_bundles = merged_bundles }

(** Rend une machine : génère le cloud-init, stocke comme provisioning_record
    et whiteliste la MAC. Retourne Ok () ou Error msg. *)
let render_and_store_machine (m : machine) : (unit, string) Stdlib.result =
  match find_profile m.mc_profile_name with
  | None -> Error (Printf.sprintf "unknown profile '%s'" m.mc_profile_name)
  | Some profile ->
    let manifest = build_manifest_for_machine profile m in
    let extra = [Fpath.v bundles_dir] in
    match Hamac_provisioning.Provisioning_gen.render ~extra_search_paths:extra manifest with
    | Error e ->
      Error (Format.asprintf "%a" Hamac_provisioning.Provisioning_gen.pp_error e)
    | Ok r ->
      let record = {
        pr_profile_name = r.Hamac_provisioning.Provisioning_gen.profile_name;
        pr_cloud_init = r.Hamac_provisioning.Provisioning_gen.cloud_init;
        pr_ipxe_script = r.Hamac_provisioning.Provisioning_gen.ipxe_script;
        pr_os_image_url = r.Hamac_provisioning.Provisioning_gen.os_image_url;
        pr_os_image_sha256 = r.Hamac_provisioning.Provisioning_gen.os_image_sha256;
        pr_os_format = r.Hamac_provisioning.Provisioning_gen.os_format;
        pr_created_at = Unix.gettimeofday ();
      } in
      Hashtbl.replace provisioning m.mc_mac record;
      save_provisioning_to_disk m.mc_mac record;
      (* Whiteliste la MAC (entrée allowed_mac dérivée de la machine) *)
      let am = {
        am_mac = m.mc_mac;
        am_label = Printf.sprintf "machine:%s" m.mc_profile_name;
        am_added_by = "hamac-machine";
        am_added_at = Unix.gettimeofday ();
      } in
      Hashtbl.replace allowed_macs m.mc_mac am;
      save_allowed_macs_to_disk ();
      Ok ()

(* ---- Handlers ---- *)

let handle_profiles_list () =
  let entries = List.map (fun (n, p) -> profile_to_json n p) (catalog ()) in
  respond_json ~status:`OK (`Assoc ["profiles", `List entries])

let handle_machines_list () =
  let entries = Hashtbl.fold (fun _ m acc -> machine_to_json m :: acc) machines [] in
  respond_json ~status:`OK (`Assoc ["machines", `List entries])

let handle_machine_get mac =
  let mac = normalize_mac mac in
  match Hashtbl.find_opt machines mac with
  | None -> respond_error 404 ("No machine for " ^ mac)
  | Some m -> respond_json ~status:`OK (machine_to_json m)

let handle_machine_create body_str =
  match (try Ok (Yojson.Safe.from_string body_str)
         with e -> Error (Printexc.to_string e)) with
  | Error e -> respond_error 400 ("Invalid JSON: " ^ e)
  | Ok j ->
    match machine_of_json j with
    | Error msg -> respond_error 400 msg
    | Ok m0 ->
      let m = { m0 with mc_status = "pending";
                        mc_updated_at = Unix.gettimeofday () } in
      (match render_and_store_machine m with
       | Error msg -> respond_error 400 msg
       | Ok () ->
         Hashtbl.replace machines m.mc_mac m;
         save_machine_to_disk m;
         Lwt.async (fun () ->
           broadcast_event "machine-updated"
             (`Assoc ["mac", `String m.mc_mac;
                      "profile", `String m.mc_profile_name]));
         respond_json ~status:`Created (machine_to_json m))

let handle_machine_delete mac =
  let mac = normalize_mac mac in
  if Hashtbl.mem machines mac then begin
    Hashtbl.remove machines mac;
    delete_machine_from_disk mac;
    (* Retire aussi le provisioning record + la whitelist dérivés *)
    Hashtbl.remove provisioning mac;
    delete_provisioning_from_disk mac;
    Hashtbl.remove allowed_macs mac;
    save_allowed_macs_to_disk ();
    Lwt.async (fun () ->
      broadcast_event "machine-deleted" (`Assoc ["mac", `String mac]));
    respond_json ~status:`OK (`Assoc ["status", `String "deleted"; "mac", `String mac])
  end else
    respond_error 404 ("No machine for " ^ mac)

let get_client_ip _conn =
  (* In production, parse X-Forwarded-For or connection info *)
  "unknown"

(** Main HTTP handler *)
let http_handler conn req body =
  let uri = Cohttp.Request.uri req in
  let meth = Cohttp.Request.meth req in
  let path = Uri.path uri in

  (* Extract path segments *)
  let segments = String.split_on_char '/' path |> List.filter (fun s -> s <> "") in
  let client_ip = get_client_ip conn in

  match meth, segments with
  (* CORS preflight *)
  | `OPTIONS, _ ->
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers:json_headers ~body:"" ()

  (* Health check *)
  | `GET, ["health"] ->
      handle_health ()

  (* Cluster config *)
  | `GET, ["config"] ->
      handle_get_config ()

  | `POST, ["config"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_set_config body_str

  (* Register node *)
  | `POST, ["register"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_register body_str client_ip

  (* List all nodes *)
  | `GET, ["nodes"] ->
      handle_list_nodes ()

  (* Get specific node *)
  | `GET, ["nodes"; id] ->
      handle_get_node id

  (* Get cloud-init for node *)
  | `GET, ["nodes"; id; "cloud-init"] ->
      handle_cloud_init id

  (* Get services assigned to node *)
  | `GET, ["nodes"; id; "services"] ->
      handle_node_services id

  (* Node heartbeat *)
  | `POST, ["nodes"; id; "heartbeat"] ->
      handle_heartbeat id

  (* Node reports service status *)
  | `POST, ["nodes"; id; "service-status"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_service_status id body_str

  (* Delete node *)
  | `DELETE, ["nodes"; id] ->
      handle_delete_node id

  (* List available images *)
  | `GET, ["images"] ->
      handle_list_images ()

  (* Serve specific image *)
  | `GET, ["images"; filename] ->
      handle_serve_image filename

  (* List all services *)
  | `GET, ["services"] ->
      handle_list_services ()

  (* Deploy a service *)
  | `POST, ["services"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_deploy_service body_str

  (* Get specific service *)
  | `GET, ["services"; name] ->
      handle_get_service name

  (* Get service binary *)
  | `GET, ["services"; name; "binary"] ->
      handle_service_binary name

  (* Get service config *)
  | `GET, ["services"; name; "config"] ->
      handle_service_config name

  (* Delete service *)
  | `DELETE, ["services"; name] ->
      handle_delete_service name

  (* Check infrastructure constraints *)
  | `POST, ["constraints"; "check"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_check_constraints body_str

  (* Provisioning profiles (pushed by hamac) *)
  | `GET, ["provisioning"] ->
      handle_provisioning_list ()
  | `POST, ["provisioning"; mac] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_provisioning_push mac body_str
  | `GET, ["provisioning"; mac] ->
      handle_provisioning_get mac
  | `GET, ["provisioning"; mac; "cloud-init"] ->
      handle_provisioning_get_cloud_init mac
  | `GET, ["provisioning"; mac; "ipxe"] ->
      handle_provisioning_get_ipxe mac
  | `DELETE, ["provisioning"; mac] ->
      handle_provisioning_delete mac

  (* Allowed MACs (whitelist gérée via UI, propagée à dnsmasq) *)
  | `GET, ["api"; "allowed-macs"] ->
      handle_allowed_macs_list ()
  | `POST, ["api"; "allowed-macs"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_allowed_macs_add body_str
  | `DELETE, ["api"; "allowed-macs"; mac] ->
      handle_allowed_macs_delete mac
  (* Endpoint consommé par le sidecar dnsmasq dans le container hamac-pxe.
     Renvoie le contenu du fichier dnsmasq dhcp-hostsfile, qui sera
     rechargé via SIGHUP. *)
  | `GET, ["api"; "allowed-macs"; "dnsmasq-hostsfile"] ->
      handle_allowed_macs_dnsmasq_hostsfile ()

  (* Catalogue de profils (mode b, UI) *)
  | `GET, ["api"; "profiles"] ->
      handle_profiles_list ()

  (* Machines (mode b : mac + profil + params, rendu auto par le discovery) *)
  | `GET, ["api"; "machines"] ->
      handle_machines_list ()
  | `POST, ["api"; "machines"] ->
      Cohttp_lwt.Body.to_string body >>= fun body_str ->
      handle_machine_create body_str
  | `GET, ["api"; "machines"; mac] ->
      handle_machine_get mac
  | `DELETE, ["api"; "machines"; mac] ->
      handle_machine_delete mac

  (* Dashboard - real-time visualization *)
  | `GET, ["dashboard"] ->
      handle_dashboard ()

  (* SSE events stream for real-time updates *)
  | `GET, ["events"] ->
      handle_events ()

  (* API state snapshot for dashboard *)
  | `GET, ["api"; "state"] ->
      handle_api_state ()

  (* Not found *)
  | _ ->
      respond_error 404 (Printf.sprintf "Not found: %s %s"
        (Cohttp.Code.string_of_method meth) path)

(** Entry point *)
let () =
  let port =
    try int_of_string (Sys.getenv "PORT")
    with _ -> 8877
  in

  Printf.printf "=== SIESTE Infrastructure Discovery Server ===\n";
  Printf.printf "Listening on port %d\n" port;
  Printf.printf "\n";
  Printf.printf "Endpoints:\n";
  Printf.printf "  POST   /register              - Register a node\n";
  Printf.printf "  GET    /nodes                 - List all nodes\n";
  Printf.printf "  GET    /nodes/:id             - Get node by ID\n";
  Printf.printf "  GET    /nodes/:id/cloud-init  - Get cloud-init config\n";
  Printf.printf "  DELETE /nodes/:id             - Remove node\n";
  Printf.printf "  GET    /config                - Get cluster config\n";
  Printf.printf "  POST   /config                - Set cluster config\n";
  Printf.printf "  GET    /images                - List available OS images\n";
  Printf.printf "  GET    /images/:name          - Download OS image\n";
  Printf.printf "  GET    /services              - List deployed services\n";
  Printf.printf "  POST   /services              - Deploy a service\n";
  Printf.printf "  GET    /services/:name        - Get service status\n";
  Printf.printf "  DELETE /services/:name        - Remove a service\n";
  Printf.printf "  POST   /constraints/check     - Check infra constraints\n";
  Printf.printf "  GET    /provisioning          - List provisioning profiles\n";
  Printf.printf "  POST   /provisioning/<mac>    - Push a profile (from hamac)\n";
  Printf.printf "  GET    /provisioning/<mac>    - Get profile JSON\n";
  Printf.printf "  GET    /provisioning/<mac>/cloud-init - Cloud-init YAML\n";
  Printf.printf "  GET    /provisioning/<mac>/ipxe        - iPXE script\n";
  Printf.printf "  DELETE /provisioning/<mac>    - Remove profile\n";
  Printf.printf "  GET    /api/allowed-macs      - List allowed MAC entries\n";
  Printf.printf "  POST   /api/allowed-macs      - Add a MAC ({mac,label})\n";
  Printf.printf "  DELETE /api/allowed-macs/<mac> - Remove a MAC\n";
  Printf.printf "  GET    /api/allowed-macs/dnsmasq-hostsfile - dnsmasq dhcp-hostsfile body\n";
  Printf.printf "  GET    /health                - Health check\n";
  Printf.printf "\n";
  Printf.printf "Dashboard & Real-time:\n";
  Printf.printf "  GET    /dashboard             - Web dashboard UI\n";
  Printf.printf "  GET    /events                - SSE events stream\n";
  Printf.printf "  GET    /api/state             - Full state snapshot\n";
  Printf.printf "\n";
  Printf.printf "Environment variables:\n";
  Printf.printf "  PORT       - Server port (default: 8877)\n";
  Printf.printf "  IMAGES_DIR - Directory containing OS images (default: ./images)\n";
  Printf.printf "  IMAGE_URL  - Default image URL for provisioning\n";
  Printf.printf "  K3S_URL    - k3s server URL for cluster join\n";
  Printf.printf "  K3S_TOKEN  - k3s cluster token\n";
  Printf.printf "  HAMAC_DISCOVERY_STATE - State dir for provisioning profiles\n";
  Printf.printf "                          (default: /var/lib/hamac-discovery)\n";
  Printf.printf "\n";

  (* Charger les profils de provisioning persistés *)
  load_provisioning_from_disk ();
  if Hashtbl.length provisioning > 0 then
    Printf.printf "Loaded %d provisioning profile(s) from %s\n%!"
      (Hashtbl.length provisioning) (provisioning_dir ());

  (* Charger la whitelist des MACs autorisées *)
  load_allowed_macs_from_disk ();
  if Hashtbl.length allowed_macs > 0 then
    Printf.printf "Loaded %d allowed MAC(s) from %s\n%!"
      (Hashtbl.length allowed_macs) (allowed_macs_file ());

  (* Charger les machines (mode b) et afficher la taille du catalogue *)
  load_machines_from_disk ();
  if Hashtbl.length machines > 0 then
    Printf.printf "Loaded %d machine(s) from %s\n%!"
      (Hashtbl.length machines) (machines_dir ());
  Printf.printf "Profile catalog: %d profile(s) (builtin=%s, custom=%s)\n%!"
    (List.length (catalog ())) builtin_profiles_dir (custom_profiles_dir ());
  Printf.printf "Example registration:\n";
  Printf.printf "  curl -X POST http://localhost:%d/register \\\n" port;
  Printf.printf "       -H 'Content-Type: application/json' \\\n";
  Printf.printf "       -d '{\"hostname\":\"node1\",\"ip_address\":\"10.99.0.100\",\n";
  Printf.printf "            \"mac_address\":\"52:54:00:12:34:56\",\"cpus\":4,\n";
  Printf.printf "            \"memory_mb\":8192,\"disk_gb\":100}'\n";
  Printf.printf "\n";
  Printf.printf "Example service deployment:\n";
  Printf.printf "  curl -X POST http://localhost:%d/services \\\n" port;
  Printf.printf "       -H 'Content-Type: application/json' \\\n";
  Printf.printf "       -d '{\"name\":\"my-api\",\"runtime\":\"http\",\n";
  Printf.printf "            \"ports\":[8080],\"replicas\":2}'\n";
  Printf.printf "\n%!";

  let callback = http_handler in
  let server = Cohttp_lwt_unix.Server.make ~callback () in

  Lwt_main.run (
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) server
  )
