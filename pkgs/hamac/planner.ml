(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Infrastructure planner for hamac.

    Infers infrastructure requirements from service manifests.
    Produces a proposed topology: nodes, network segments, firewall rules.
    This is the "zero touch" core — the user defines services,
    the planner figures out what infrastructure is needed.

    The placement is computed by clingo ({!Hamac_clingo.Clingo}): the ASP
    form of the manifests ({!Hamac_manifest.Loaf_source.asp}) and the
    program of the planner, [hamac.lp] (embedded in the executable as
    {!Hamac_lp.text}), which places every replica of every service to
    deploy on a node of its zone, within the capacity of a node and the
    spread the service asks for, with as few nodes as possible. Everything
    the plan says about resources (demand of a replica, number of replicas,
    nodes) is read from the optimal model: [hamac.lp] is its only source. *)

open Hamac_manifest.Types

module Clingo = Hamac_clingo.Clingo

(** Zone of a service (default: "default"), cf. {!Hamac_manifest.Flows.service_zone}. *)
let service_zone = Hamac_manifest.Flows.service_zone

(** Max replicas considering autoscaling *)
let service_max_replicas (svc : service_manifest) : int =
  match svc.autoscaling with
  | Some a -> a.max_replicas
  | None -> svc.replicas

(* ============================================================ *)
(* Topology parameters                                           *)
(* ============================================================ *)

(** Standard node size of a proposed topology, given to [hamac.lp] as the
    constants [node_memory] and [node_cpu]. *)
let node_ram_mb = 4096    (* 4 GB per node *)
let node_cpu_milli = 4000 (* 4 cores per node *)

(** Zone to CIDR mapping (deterministic) *)
let zone_cidr (zone_index : int) : string =
  Printf.sprintf "10.%d.0.0/24" (10 + zone_index)

(** Zone to VLAN ID (deterministic) *)
let zone_vlan (zone_index : int) : int =
  100 + zone_index

(* ============================================================ *)
(* Plan                                                          *)
(* ============================================================ *)

type zone_info = {
  zone_name: string;
  services: string list;  (** in the order of the services given to {!plan} *)
  total_memory_mb: int;
  total_cpu_milli: int;
  total_replicas: int;
  nodes: int;             (** nodes of the optimal placement *)
}

(** A replica and the node it is placed on: [node] is the rank of the
    node in its zone, from 0 (cf. [Infra_sim.node_name]). *)
type replica = {
  service: string;
  index: int;             (** from 1 *)
  zone: string;
  node: int;
}

type plan = {
  infrastructure: infrastructure_manifest;
  zones: zone_info list;
  placement: replica list;  (** sorted by zone, node, service, index *)
  warnings: string list;
}

(** The services cannot be placed: a replica larger than a node, no
    placement satisfying the constraints, or an error of clingo. *)
exception Error of string list

(* ============================================================ *)
(* Solving                                                       *)
(* ============================================================ *)

(** What the optimal model of [hamac.lp] says, by service (its Hamac name,
    cf. {!Hamac_manifest.Loaf_source.dns}). *)
type demand = {
  d_zone: string;
  d_replicas: int;
  d_memory_mb: int;  (** per replica *)
  d_cpu_milli: int;  (** per replica *)
}

let const = function Clingo.Fun (c, []) -> Some c | _ -> None
let service_name = function
  | Clingo.Fun (c, []) -> Some (Hamac_manifest.Loaf_source.dns c)
  | _ -> None

(** Default bound on the search for the optimal placement, in seconds. *)
let default_time_limit = 30.

(** The best model of the manifests [asp] and [hamac.lp] that clingo finds
    within [time_limit] seconds, and whether it is proven optimal. *)
let solve ~time_limit (asp : string list) : Clingo.model * bool =
  let args = [ Printf.sprintf "--const=node_memory=%d" node_ram_mb;
               Printf.sprintf "--const=node_cpu=%d" node_cpu_milli ] in
  match
    Clingo.with_control ~args (fun ctl ->
      Clingo.add ctl (String.concat "\n" asp);
      Clingo.add ctl Hamac_lp.text;
      Clingo.ground ctl;
      let r = Clingo.fold ~time_limit ctl ~init:None (fun _ m -> Some m) in
      (* Atoms that no rule defines are expected (the manifests use a part
         of the vocabulary); the other messages are for debugging. *)
      List.iter (fun (w, msg) ->
        if w <> Clingo.Atom_undefined then Logs.debug (fun f -> f "clingo: %s" msg))
        (Clingo.messages ctl);
      r)
  with
  | Some m, outcome -> (m, outcome.exhausted)
  | None, { satisfiable = Some false; _ } ->
    raise (Error [ "no placement of the services satisfies the constraints" ])
  | None, _ ->
    raise (Error [ Printf.sprintf "no placement found within the time limit (%gs)" time_limit ])
  | exception Clingo.Error e -> raise (Error [ Fmt.str "%a" Clingo.pp_error e ])

(** The demand of each service and the placement of its replicas, read
    from the optimal model. *)
let read_model (m : Clingo.model) =
  let tbl : (string, demand) Hashtbl.t = Hashtbl.create 16 in
  let get s = Option.value (Hashtbl.find_opt tbl s)
      ~default:{ d_zone = "default"; d_replicas = 0; d_memory_mb = 0; d_cpu_milli = 0 } in
  let set s f = Hashtbl.replace tbl s (f (get s)) in
  let placement = ref [] and oversized = ref [] and errors = ref [] in
  List.iter (fun (sym : Clingo.symbol) ->
    match sym with
    | Fun ("zone_of", [s; z]) ->
      Option.iter (fun s -> Option.iter (fun z -> set s (fun d -> { d with d_zone = z })) (const z))
        (service_name s)
    | Fun ("replicas", [s; Int n]) ->
      Option.iter (fun s -> set s (fun d -> { d with d_replicas = n })) (service_name s)
    | Fun ("memory", [s; Int n]) ->
      Option.iter (fun s -> set s (fun d -> { d with d_memory_mb = n })) (service_name s)
    | Fun ("cpu", [s; Int n]) ->
      Option.iter (fun s -> set s (fun d -> { d with d_cpu_milli = n })) (service_name s)
    | Fun ("place", [s; Int index; Fun ("", [z; Int k])]) ->
      (match service_name s, const z with
       | Some service, Some zone -> placement := { service; index; zone; node = k - 1 } :: !placement
       | _ -> ())
    | Fun ("oversized", [s; Int mem; Int cpu]) ->
      Option.iter (fun s ->
        oversized := Printf.sprintf
            "service '%s': a replica needs %d MiB and %d mCPU, more than a node offers \
             (%d MiB, %d mCPU)" s mem cpu node_ram_mb node_cpu_milli :: !oversized)
        (service_name s)
    | Fun ("error", [msg; _]) ->
      (* A message of the vocabulary starts with its code ([[E013] …]), a
         string or the first piece of a cat(…) that LOAF concatenates; a
         warning ([W…]) does not stop the plan. *)
      let head = match msg with Str s | Fun ("cat", Str s :: _) -> s | _ -> "" in
      if not (String.starts_with ~prefix:"[W" head) then
        errors := Fmt.str "%a" Clingo.pp_symbol msg :: !errors
    | _ -> ()) m.symbols;
  (* The manifests were accepted by LOAF, which computes the same error/2
     atoms: one here means that clingo and LOAF disagree on the model. *)
  if !errors <> [] then
    raise (Error (List.map (fun e -> "internal error: clingo derives the error " ^ e
                                      ^ ", which LOAF did not report") (List.rev !errors)));
  if !oversized <> [] then raise (Error (List.rev !oversized));
  let placement = List.sort (fun a b ->
    compare (a.zone, a.node, a.service, a.index) (b.zone, b.node, b.service, b.index)) !placement in
  (tbl, placement)

(* ============================================================ *)
(* Plan generation                                               *)
(* ============================================================ *)

(** Generate an infrastructure proposal from service manifests and the
    flows they declare (already checked by {!Hamac_manifest.Flows.declared}).
    [asp] is the ASP form of the set of files the services come from
    ({!Hamac_manifest.Loaf_source.asp}); [services] are the services to
    deploy, the same as those that [hamac.lp] derives from it. The search
    stops after [time_limit] seconds ({!default_time_limit}): the plan then
    has the best placement found, and a warning.
    @raise Error if the services cannot be placed. *)
let plan ?lattice ?(time_limit = default_time_limit) ~(name : string)
    ~(flows : Hamac_manifest.Flows.flow list)
    ~(asp : string list) (services : service_manifest list) : plan =
  let model, proven = solve ~time_limit asp in
  let demands, placement = read_model model in
  let given = List.sort_uniq String.compare (List.map (fun (s : service_manifest) -> s.name) services) in
  let derived = List.sort String.compare (Hashtbl.fold (fun s _ acc -> s :: acc) demands []) in
  if given <> derived then
    raise (Error [ Printf.sprintf
                     "internal error: the services to deploy (%s) differ from those of hamac.lp (%s)"
                     (String.concat ", " given) (String.concat ", " derived) ]);
  let zone_names = List.sort_uniq String.compare
      (Hashtbl.fold (fun _ d acc -> d.d_zone :: acc) demands []) in
  let zones = List.map (fun zone ->
    let members = List.filter_map (fun (svc : service_manifest) ->
      let d = Hashtbl.find demands svc.name in
      if d.d_zone = zone then Some (svc.name, d) else None) services in
    let sum f = List.fold_left (fun acc (_, d) -> acc + f d) 0 members in
    { zone_name = zone;
      services = List.map fst members;
      total_memory_mb = sum (fun d -> d.d_memory_mb * d.d_replicas);
      total_cpu_milli = sum (fun d -> d.d_cpu_milli * d.d_replicas);
      total_replicas = sum (fun d -> d.d_replicas);
      nodes = List.length (List.sort_uniq Int.compare
          (List.filter_map (fun r -> if r.zone = zone then Some r.node else None) placement)) })
    zone_names in
  let warnings = ref [] in
  if not proven then
    warnings := Printf.sprintf
        "The placement is not proven optimal: the search for fewer nodes stopped at the \
         time limit (%gs)" time_limit :: !warnings;

  (* Generate nodes — one group per zone *)
  let nodes = List.map (fun (z : zone_info) ->
    let count = z.nodes in
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
  let firewall = Hamac_manifest.Flows.firewall_rules ?lattice (List.map (fun z -> z.zone_name) zones) flows in

  let infrastructure = {
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
    certificate = None;
  } in

  { infrastructure; zones; placement; warnings = List.rev !warnings }

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
    ) z.services
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
         Logs.app (fun m -> m "  %s" (firewall_rule_to_string r))
       ) topo.firewall;
       if List.exists (fun (r : firewall_rule) -> r.action = Allow) topo.firewall then
         Logs.app (fun m -> m "  Stateful: replies to an allowed connection pass.");
       Logs.app (fun m -> m "")
     end
   | None -> ());

  (* Warnings *)
  List.iter (fun w ->
    Logs.warn (fun m -> m "%s" w)
  ) p.warnings
