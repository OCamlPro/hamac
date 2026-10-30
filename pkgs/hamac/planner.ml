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
    spread the service asks for, with as few nodes as possible, and the
    rules of the constraints and objectives of the patterns. Everything
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

(** The services cannot be placed: a replica larger than a node, hard
    constraints of the patterns that no placement satisfies, or an error of
    clingo. *)
exception Error of string list

(* ============================================================ *)
(* Solving                                                       *)
(* ============================================================ *)

(** What the optimal model of [hamac.lp] says, by service (its Hamac name,
    as the files write it). *)
type demand = {
  d_zone: string;
  d_replicas: int;
  d_memory_mb: int;  (** per replica *)
  d_cpu_milli: int;  (** per replica *)
}

let const = function Clingo.Fun (c, []) -> Some c | _ -> None
let service_name = function
  | Clingo.Fun (c, []) -> Some c
  | _ -> None

(* ============================================================ *)
(* Rules of the patterns                                         *)
(* ============================================================ *)

(** A rule that a constraint or an objective of a pattern adds to
    [hamac.lp], and the declaration it comes from. *)
type rule = {
  text: string;
  pattern: string;
  subject: string;        (** ["constraint c"], ["minimize \"…\""] *)
  loc: Hamac_manifest.Diagnostic.loc option;
}

(** [s] as a string of clingo. *)
let asp_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (function
    | '"' -> Buffer.add_string b "\\\""
    | '\\' -> Buffer.add_string b "\\\\"
    | '\n' -> Buffer.add_string b "\\n"
    | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

(** The position of the first [c] of [s] outside strings and brackets. *)
let find_top c s =
  let n = String.length s in
  let rec go i depth in_str =
    if i >= n then None
    else match s.[i] with
      | '\\' when in_str -> go (i + 2) depth in_str
      | '"' -> go (i + 1) depth (not in_str)
      | _ when in_str -> go (i + 1) depth in_str
      | '(' | '{' | '[' -> go (i + 1) (depth + 1) in_str
      | ')' | '}' | ']' -> go (i + 1) (depth - 1) in_str
      | ch when ch = c && depth = 0 -> Some i
      | _ -> go (i + 1) depth in_str
  in
  go 0 0 false

(** [terms : body] split at its colon. *)
let split_element s =
  match find_top ':' s with
  | None -> None
  | Some i ->
    Some (String.trim (String.sub s 0 i),
          String.trim (String.sub s (i + 1) (String.length s - i - 1)))

(* One rule per line: {!rule_of_message} finds a rule by its line. *)
let one_line = String.map (function '\n' | '\r' -> ' ' | c -> c)

let rule_text head body =
  one_line (if body = "" then head ^ "." else head ^ " :- " ^ body ^ ".")

(** The rules of the constraints and objectives of [patterns]: a
    constraint [terms : body] derives [violation_of(V, (terms))], an
    objective [weight, terms : body] [minimize_term(E, weight, (terms))]
    or [maximize_term(…)], where [V] and [E] are the declarations
    themselves, which [hamac.lp] joins to the facts of the patterns. A
    declaration without its colon is returned as an E052 diagnostic. *)
let pattern_rules (patterns : pattern_manifest list)
  : rule list * Hamac_manifest.Diagnostic.t list =
  let module D = Hamac_manifest.Diagnostic in
  let malformed ?loc what expected =
    D.make ?loc "E052" [] (Printf.sprintf "%s: expected '%s'" what expected) in
  List.fold_left (fun (rules, diags) (p : pattern_manifest) ->
    let rules, diags = List.fold_left (fun (rules, diags) (c : constraint_decl) ->
      let subject = "constraint " ^ c.cid in
      match split_element c.violation with
      | None -> (rules, malformed ?loc:c.cloc (subject ^ " of " ^ p.pat_name) "terms : body" :: diags)
      | Some (terms, body) ->
        let head = Printf.sprintf "violation_of(%s, (%s))" (asp_string c.violation) terms in
        ({ text = rule_text head body; pattern = p.pat_name; subject; loc = c.cloc } :: rules, diags))
      (rules, diags) p.constraints in
    List.fold_left (fun (rules, diags) (o : objective) ->
      let subject = Printf.sprintf "%s %S" o.direction o.element in
      let split = Option.bind (split_element o.element) (fun (left, body) ->
        match find_top ',' left with
        | Some i -> Some (String.trim (String.sub left 0 i),
                          String.trim (String.sub left (i + 1) (String.length left - i - 1)), body)
        | None -> if left = "" then None else Some (left, "", body)) in
      match split with
      | None -> (rules, malformed ?loc:o.oloc (subject ^ " of " ^ p.pat_name) "weight, terms : body" :: diags)
      | Some (weight, terms, body) ->
        let head = Printf.sprintf "%s_term(%s, %s, (%s))" o.direction (asp_string o.element) weight terms in
        ({ text = rule_text head body; pattern = p.pat_name; subject; loc = o.oloc } :: rules, diags))
      (rules, diags) p.objectives)
    ([], []) patterns
  |> fun (rules, diags) -> (List.rev rules, List.rev diags)

(** The program of a plan: the manifests, [hamac.lp], then the rules of
    the patterns, one per line, and the line of the first rule. *)
let program asp rules =
  let prefix = String.concat "\n" (asp @ [ Hamac_lp.text ]) in
  let first = 2 + List.length (String.split_on_char '\n' prefix) - 1 in
  (String.concat "\n" (prefix :: List.map (fun r -> r.text) rules), first)

(** The rule a message of clingo is about, by its line ([<block>:12:3-8:]),
    and the message without its location. *)
let rule_of_message rules first ((w, msg) : Clingo.warning * string) =
  let located line =
    match String.index_opt line ':' with
    | None -> None
    | Some i ->
      match String.split_on_char ':' (String.sub line (i + 1) (String.length line - i - 1)) with
      | l :: _ :: rest ->
        Option.map (fun l -> (l, String.trim (String.concat ":" rest))) (int_of_string_opt l)
      | _ -> None in
  match located msg with
  | Some (l, text) when l >= first && l - first < List.length rules ->
    (* The notes that follow ([<block>:12:5-6: note: 'X' is unsafe]) say
       which term is at fault; the rule as clingo prints it does not help. *)
    let lines = String.split_on_char '\n' text in
    let notes = match w, lines with
      | Clingo.Atom_undefined, _ :: atom :: _ -> [ String.trim atom ]   (* the atom at fault *)
      | _ -> List.filter_map (fun line ->
          match located (String.trim line) with
          | Some (_, n) when String.starts_with ~prefix:"note: " n ->
            Some (String.sub n 6 (String.length n - 6))
          | _ -> None) lines in
    let strip t = List.fold_left (fun t p ->
      if String.starts_with ~prefix:p t then String.sub t (String.length p) (String.length t - String.length p)
      else t) t [ "error: "; "info: " ] in
    let head = strip (List.hd lines) in
    let head = List.fold_left (fun h suffix ->
      if String.ends_with ~suffix h then String.sub h 0 (String.length h - String.length suffix) else h)
      head [ ":"; " in" ] in
    let head = if notes = [] then head else head ^ ":" in
    Some (List.nth rules (l - first), String.concat " " (head :: notes))
  | _ -> None

(** Checks the rules of the constraints and objectives of [patterns]
    against the manifests [asp] and [hamac.lp], by grounding them: a
    syntax error, an unsafe variable or a predicate that no rule defines
    gives E052, at the declaration. *)
let check ~(asp : string list) (patterns : pattern_manifest list) : Hamac_manifest.Diagnostic.t list =
  let module D = Hamac_manifest.Diagnostic in
  let rules, malformed = pattern_rules patterns in
  if rules = [] then malformed
  else
    let text, first = program asp rules in
    (* Without a limit on the messages: clingo stops reporting after the
       limit, and a rule of a pattern would then go unchecked. *)
    let messages = Clingo.with_control ~message_limit:1_000_000 (fun ctl ->
      (try Clingo.add ctl text; Clingo.ground ctl with Clingo.Error _ -> ());
      Clingo.messages ctl) in
    let found = List.filter_map (rule_of_message rules first) messages in
    malformed @ List.map (fun (r, msg) ->
      D.make ?loc:r.loc "E052" [] (Printf.sprintf "%s of %s: %s" r.subject r.pattern msg)) found

(** Default bound on the search for the optimal placement, in seconds. *)
let default_time_limit = 30.

(** The best model of the manifests [asp], [hamac.lp] and the rules of the
    patterns that clingo finds within [time_limit] seconds, and whether it
    is proven optimal. With [relax], the hard constraints of the patterns
    become penalties above every objective: the model then says which ones
    no placement satisfies. *)
let solve ?(relax = false) ~time_limit (asp : string list) (patterns : pattern_manifest list)
  : Clingo.model option * Clingo.outcome =
  let rules, _ = pattern_rules patterns in
  let top = List.fold_left (fun acc (p : pattern_manifest) ->
    List.fold_left max acc
      (List.map (fun (c : constraint_decl) -> c.cpriority) p.constraints
       @ List.map (fun (o : objective) -> o.priority) p.objectives)) 0 patterns in
  let args = [ Printf.sprintf "--const=node_memory=%d" node_ram_mb;
               Printf.sprintf "--const=node_cpu=%d" node_cpu_milli;
               Printf.sprintf "--const=relax=%d" (if relax then 1 else 0);
               Printf.sprintf "--const=relax_priority=%d" (top + 1) ] in
  match
    Clingo.with_control ~args (fun ctl ->
      Clingo.add ctl (fst (program asp rules));
      Clingo.ground ctl;
      let r = Clingo.fold ~time_limit ctl ~init:None (fun _ m -> Some m) in
      (* The program was checked ({!check}): messages are for debugging. *)
      List.iter (fun (_, msg) -> Logs.debug (fun f -> f "clingo: %s" msg)) (Clingo.messages ctl);
      r)
  with
  | r -> r
  | exception Clingo.Error e -> raise (Error [ Fmt.str "%a" Clingo.pp_error e ])

(** A violation of a constraint, read from a model: the pattern, the
    constraint and its witness. *)
let violations (m : Clingo.model) =
  List.filter_map (function
    | Clingo.Fun ("violation", [p; c; w]) ->
      Some (Fmt.str "constraint %a of pattern %a (%a)"
              Clingo.pp_symbol c Clingo.pp_symbol p Clingo.pp_symbol w)
    | _ -> None) m.symbols

(** The optimal placement, or the hard constraints that make it
    impossible. *)
let solve_plan ~time_limit asp patterns : Clingo.model * bool =
  match solve ~time_limit asp patterns with
  | Some m, outcome -> (m, outcome.exhausted)
  | None, { satisfiable = Some false; _ } ->
    let culprits = match solve ~relax:true ~time_limit asp patterns with
      | Some m, _ -> violations m
      | None, _ -> [] in
    raise (Error (match culprits with
      | [] -> [ "no placement of the services satisfies the constraints" ]
      | vs -> List.map (fun v -> "no placement of the services satisfies the " ^ v) vs))
  | None, _ ->
    raise (Error [ Printf.sprintf "no placement found within the time limit (%gs)" time_limit ])

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
    deploy, the same as those that [hamac.lp] derives from it; [patterns],
    those of the stack, whose constraints and objectives ({!pattern_rules})
    are added to [hamac.lp]: a violated soft constraint gives a warning. The search
    stops after [time_limit] seconds ({!default_time_limit}): the plan then
    has the best placement found, and a warning.
    @raise Error if the services cannot be placed. *)
let plan ?lattice ?(time_limit = default_time_limit) ~(name : string)
    ~(flows : Hamac_manifest.Flows.flow list)
    ~(asp : string list) ?(patterns = []) (services : service_manifest list) : plan =
  let model, proven = solve_plan ~time_limit asp patterns in
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
  let warnings = ref (List.rev_map (fun v -> "soft " ^ v ^ " is violated") (violations model)) in
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
    backend = "docker_compose";
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
