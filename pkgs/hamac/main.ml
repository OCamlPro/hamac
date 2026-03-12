open Ocamlpro_cli
open Ocamlpro_codec

(* ============================================================ *)
(* State                                                         *)
(* ============================================================ *)

let manifest_files = ref []

(* ============================================================ *)
(* Helpers                                                       *)
(* ============================================================ *)

let kind_label = function
  | Manifest_types.MService s ->
    Printf.sprintf "service (name=%s, runtime=%s)" s.name s.runtime
  | MStack s ->
    Printf.sprintf "stack (name=%s, %d services)" s.name (List.length s.services)
  | MInfrastructure i ->
    Printf.sprintf "infrastructure (name=%s, backend=%s)" i.name i.backend

(** Load a registry from default search paths *)
let load_registry () =
  let registry = Provider_registry.create () in
  Provider_registry.load_defaults registry;
  registry

(** Load services and stack overrides from file arguments *)
let load_services_and_overrides () =
  let services = ref [] in
  let overrides = ref [] in
  List.iter (fun path ->
    let fpath = Fpath.v path in
    match Manifest_parser.load_file fpath with
    | Error msg ->
      Logs.err (fun m -> m "%s" msg);
      exit 1
    | Ok (Manifest_types.MService svc, _) ->
      services := svc :: !services
    | Ok (Manifest_types.MStack stk, _) ->
      (* Extract overrides from stack manifest *)
      List.iter (fun (sref : Manifest_types.stack_service_ref) ->
        let svc_overrides = List.map (fun (o : Manifest_types.stack_consume_override) ->
          (o.consume_name, o.provider)
        ) sref.consumes_override in
        if svc_overrides <> [] then begin
          (* Use ref_path basename without extension as service name *)
          let base = Filename.basename sref.ref_path in
          let name = try Filename.chop_extension base with _ -> base in
          overrides := (name, svc_overrides) :: !overrides
        end
      ) stk.services
    | Ok (other, _) ->
      Logs.warn (fun m -> m "%a: got %s (skipping)"
        Fpath.pp fpath (kind_label other))
  ) !manifest_files;
  (List.rev !services, !overrides)

(* ============================================================ *)
(* Commands                                                      *)
(* ============================================================ *)

let run_validate () =
  let ok = ref true in
  List.iter (fun path ->
    let fpath = Fpath.v path in
    match Manifest_parser.load_file fpath with
    | Error msg ->
      Logs.err (fun m -> m "%s" msg);
      ok := false
    | Ok (manifest, warnings) ->
      Logs.app (fun m -> m "%a: %s" Fpath.pp fpath (kind_label manifest));
      List.iter (fun w ->
        Logs.warn (fun m -> m "  %s" w)
      ) warnings
  ) !manifest_files;
  if not !ok then exit 1

let run_plan () =
  let services, _overrides = load_services_and_overrides () in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;
  Logs.app (fun m -> m "Planning for %d service(s):" (List.length services));
  List.iter (fun (svc : Manifest_types.service_manifest) ->
    Logs.app (fun m -> m "  - %s (%s)" svc.name svc.runtime);
    List.iter (fun (c : Manifest_types.consumption) ->
      let target = match c.capability with
        | Some cap -> Printf.sprintf "capability=%s" cap
        | None -> match c.service with
          | Some s -> Printf.sprintf "service=%s" s
          | None -> "???"
      in
      Logs.app (fun m -> m "      consumes: %s (%s)" c.name target)
    ) svc.consumes;
    (match svc.security with
     | Some sec -> Logs.app (fun m -> m "      zone: %s" sec.zone)
     | None -> ());
    (match svc.resources with
     | Some r ->
       (match r.memory_limit with
        | Some ml -> Logs.app (fun m -> m "      memory: %s" ml)
        | None -> ());
       (match r.cpu_limit with
        | Some cl -> Logs.app (fun m -> m "      cpu: %s" cl)
        | None -> ())
     | None -> ());
    Logs.app (fun m -> m "      replicas: %d" svc.replicas);
  ) services;
  Logs.app (fun m -> m "");
  Logs.app (fun m -> m "(constraint solver not yet implemented)")

let run_resolve () =
  let registry = load_registry () in
  let services, overrides = load_services_and_overrides () in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;

  let resolution = Resolver.resolve_all ~registry ~services ~overrides in

  (* Report errors *)
  List.iter (fun err ->
    Logs.err (fun m -> m "%s" err)
  ) resolution.errors;

  (* Report providers to instantiate *)
  if resolution.providers <> [] then begin
    Logs.app (fun m -> m "Providers to instantiate:");
    List.iter (fun (rp : Resolver.resolved_provider) ->
      let image = match rp.provider.Manifest_types.artifact with
        | Some a -> a.Manifest_types.path
        | None -> "?"
      in
      Logs.app (fun m -> m "  %s (%s)" rp.instance_name image);
      List.iter (fun (k, v) ->
        Logs.app (fun m -> m "    env: %s=%s" k v)
      ) rp.resolved_env
    ) resolution.providers
  end;

  (* Report wiring *)
  if resolution.wires <> [] then begin
    Logs.app (fun m -> m "");
    Logs.app (fun m -> m "Wiring:");
    List.iter (fun (w : Resolver.resolved_wire) ->
      Logs.app (fun m -> m "  %s.%s -> %s"
        w.consumer_name w.consume_name w.provider_name);
      List.iter (fun (k, v) ->
        Logs.app (fun m -> m "    inject: %s=%s" k v)
      ) w.injected_env
    ) resolution.wires
  end;

  if resolution.errors <> [] then exit 1

let run_status () =
  Logs.app (fun m -> m "No active stack.")

(* ============================================================ *)
(* CLI Arguments                                                 *)
(* ============================================================ *)

let file_arg = Cli.Argument.(remaining
  ~docv:"FILES"
  ~doc:"Manifest files (.sieste.yml)"
  Codec.string_codec
  (fun l -> manifest_files := l)
)

let debug = Cli.Argument.(flag
  ~doc:"Enable debug mode."
  ["d"; "debug"]
  (fun b ->
    if b then Logs.set_level (Some Logs.Debug))
)

(* ============================================================ *)
(* Commands                                                      *)
(* ============================================================ *)

let validate_cmd =
  let cmd = Cli.Command.make
    ~doc:"Validate manifest files."
    "validate"
    run_validate in
  Cli.Command.add_argument cmd file_arg;
  Cli.Command.add_argument cmd debug;
  cmd

let plan_cmd =
  let cmd = Cli.Command.make
    ~doc:"Plan infrastructure from service manifests."
    "plan"
    run_plan in
  Cli.Command.add_argument cmd file_arg;
  Cli.Command.add_argument cmd debug;
  cmd

let resolve_cmd =
  let cmd = Cli.Command.make
    ~doc:"Resolve service dependencies to concrete providers."
    "resolve"
    run_resolve in
  Cli.Command.add_argument cmd file_arg;
  Cli.Command.add_argument cmd debug;
  cmd

let status_cmd =
  let cmd = Cli.Command.make
    ~doc:"Show stack status."
    "status"
    run_status in
  Cli.Command.add_argument cmd debug;
  cmd

let root_cmd =
  let cmd = Cli.Command.make
    ~doc:"Hamac - stack manager for SIESTE manifests."
    "hamac"
    (fun () -> ()) in
  Cli.Command.add_command ~default:true cmd validate_cmd;
  Cli.Command.add_command cmd plan_cmd;
  Cli.Command.add_command cmd resolve_cmd;
  Cli.Command.add_command cmd status_cmd;
  cmd

let () =
  Printexc.record_backtrace true;
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Warning);
  try Cli.Command.run root_cmd
  with _ ->
    Fmt.epr "%s@." (Printexc.get_backtrace ())
