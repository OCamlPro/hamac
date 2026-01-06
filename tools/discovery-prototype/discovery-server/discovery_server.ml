(** SIESTE Infrastructure Discovery Server

    Minimal REST API for node registration and discovery.
    Nodes boot via PXE and register themselves with this server.

    Endpoints:
    - POST /register           - Register a new node
    - GET  /nodes              - List all discovered nodes
    - GET  /nodes/:id          - Get specific node info
    - GET  /nodes/:id/cloud-init - Get cloud-init config for provisioning
    - DELETE /nodes/:id        - Remove a node
    - GET  /health             - Health check
    - GET  /config             - Get cluster configuration
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

(** Global state - in production, use a database *)
let nodes : (string, node) Hashtbl.t = Hashtbl.create 16
let node_counter = ref 0

(** Generate unique node ID *)
let generate_id () =
  incr node_counter;
  Printf.sprintf "node-%04d" !node_counter

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

(** Handle GET /config *)
let handle_get_config () =
  respond_json ~status:`OK (`Assoc [
    ("k3s_url", `String !k3s_url);
    ("k3s_token", `String !k3s_token);
    ("k3s_version", `String !k3s_version);
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
    Printf.printf "[CONFIG] Updated: k3s_url=%s has_token=%b\n%!" !k3s_url (!k3s_token <> "");
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
      let cloud_init = generate_cloud_init node in
      let headers = Cohttp.Header.of_list [
        ("Content-Type", "text/yaml; charset=utf-8");
        ("Content-Disposition", Printf.sprintf "attachment; filename=\"%s-cloud-init.yaml\"" node.hostname);
      ] in
      Cohttp_lwt_unix.Server.respond_string ~status:`OK ~headers ~body:cloud_init ()
  | None ->
      respond_error 404 ("Node not found: " ^ id)

(** Extract client IP from connection *)
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

  (* Delete node *)
  | `DELETE, ["nodes"; id] ->
      handle_delete_node id

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
  Printf.printf "  GET    /health                - Health check\n";
  Printf.printf "\n";
  Printf.printf "Example registration:\n";
  Printf.printf "  curl -X POST http://localhost:%d/register \\\n" port;
  Printf.printf "       -H 'Content-Type: application/json' \\\n";
  Printf.printf "       -d '{\"hostname\":\"node1\",\"ip_address\":\"10.99.0.100\",\n";
  Printf.printf "            \"mac_address\":\"52:54:00:12:34:56\",\"cpus\":4,\n";
  Printf.printf "            \"memory_mb\":8192,\"disk_gb\":100}'\n";
  Printf.printf "\n%!";

  let callback = http_handler in
  let server = Cohttp_lwt_unix.Server.make ~callback () in

  Lwt_main.run (
    Cohttp_lwt_unix.Server.create ~mode:(`TCP (`Port port)) server
  )
