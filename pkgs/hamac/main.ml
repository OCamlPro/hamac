(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(* ============================================================ *)
(* State                                                         *)
(* ============================================================ *)

let manifest_files = ref []

(* ============================================================ *)
(* Helpers                                                       *)
(* ============================================================ *)

let kind_label = function
  | Hamac_provisioning.Manifest_types.MService s ->
    Printf.sprintf "service (name=%s, runtime=%s)" s.name s.runtime
  | MStack s ->
    Printf.sprintf "stack (name=%s, %d services)" s.name (List.length s.services)
  | MInfrastructure i ->
    Printf.sprintf "infrastructure (name=%s, backend=%s)" i.name i.backend
  | MProvisioningProfile p ->
    Printf.sprintf "provisioning_profile (name=%s, os=%s, %d bundles)"
      p.pp_name p.pp_os.os_image_name (List.length p.pp_bundles)
  | MBundle b ->
    Printf.sprintf "bundle (name=%s, version=%s, %d params)"
      b.bdl_name b.bdl_version (List.length b.bdl_params)

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
    match Hamac_provisioning.Manifest_parser.load_file fpath with
    | Error msg ->
      Logs.err (fun m -> m "%s" msg);
      exit 1
    | Ok (Hamac_provisioning.Manifest_types.MService svc, _) ->
      services := svc :: !services
    | Ok (Hamac_provisioning.Manifest_types.MStack stk, _) ->
      (* Extract overrides from stack manifest *)
      List.iter (fun (sref : Hamac_provisioning.Manifest_types.stack_service_ref) ->
        let svc_overrides = List.map (fun (o : Hamac_provisioning.Manifest_types.stack_consume_override) ->
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
    match Hamac_provisioning.Manifest_parser.load_file fpath with
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
  let plan = Planner.plan ~name:"stack" services in
  Planner.display_plan plan

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
      let image = match rp.provider.Hamac_provisioning.Manifest_types.artifact with
        | Some a -> a.Hamac_provisioning.Manifest_types.path
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

let run_simulate () =
  let registry = load_registry () in
  let services, overrides = load_services_and_overrides () in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;

  (* Plan infrastructure *)
  let plan = Planner.plan ~name:"stack" services in
  Planner.display_plan plan;

  (* Resolve providers *)
  let resolution = Resolver.resolve_all ~registry ~services ~overrides in
  List.iter (fun err -> Logs.err (fun m -> m "%s" err)) resolution.errors;
  if resolution.errors <> [] then exit 1;

  (* Generate simulation compose *)
  let compose, scripts = Infra_sim.generate ~plan ~services resolution in

  (* Write init scripts *)
  (try Unix.mkdir ".hamac" 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
  List.iter (fun (path, content) ->
    let dir = Filename.dirname path in
    (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
    let oc = open_out path in
    output_string oc content;
    close_out oc;
    Unix.chmod path 0o755
  ) scripts;

  (* Write compose file *)
  let output_path = "docker-compose.yml" in
  let oc = open_out output_path in
  output_string oc compose;
  close_out oc;

  (* Display placement *)
  let placements = Infra_sim.place_services ~plan ~resolution services in
  Logs.app (fun m -> m "");
  Infra_sim.display_placement placements;

  Logs.app (fun m -> m "");
  Logs.app (fun m -> m "Generated %s (%d nodes, %d providers, %d scripts)"
    output_path (List.length placements)
    (List.length resolution.providers) (List.length scripts));
  Logs.app (fun m -> m "Run: docker compose up -d")

let run_deploy () =
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
  if resolution.errors <> [] then exit 1;

  (* Generate docker-compose.yml *)
  let compose = Compose_gen.generate ~services resolution in
  let output_path = "docker-compose.yml" in
  let oc = open_out output_path in
  output_string oc compose;
  close_out oc;
  Logs.app (fun m -> m "Generated %s (%d services, %d providers)"
    output_path (List.length services) (List.length resolution.providers))

let run_status () =
  Logs.app (fun m -> m "No active stack.")

(* ============================================================ *)
(* provision-dryrun : génère cloud-init + iPXE pour un profil    *)
(* ============================================================ *)

let provision_bundles_dir = ref ""
let provision_mac = ref ""
let provision_discovery_url = ref "http://localhost:8877"

let run_provision_dryrun () =
  match !manifest_files with
  | [] ->
    Logs.err (fun m -> m "Provide a provisioning_profile manifest as argument.");
    exit 1
  | path :: _ ->
    let fpath = Fpath.v path in
    match Hamac_provisioning.Manifest_parser.load_file fpath with
    | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
    | Ok (Hamac_provisioning.Manifest_types.MProvisioningProfile profile, _) ->
      let extra = if !provision_bundles_dir = ""
        then []
        else [Fpath.v !provision_bundles_dir]
      in
      (match Hamac_provisioning.Provisioning_gen.render ~extra_search_paths:extra profile with
       | Error e ->
         Logs.err (fun m -> m "%a" Hamac_provisioning.Provisioning_gen.pp_error e);
         exit 1
       | Ok r ->
         print_endline "=== cloud-init ===";
         print_string r.cloud_init;
         print_endline "";
         print_endline "=== iPXE ===";
         print_string r.ipxe_script;
         print_endline "";
         Printf.printf "=== OS ===\nurl: %s\nsha256: %s\nformat: %s\n"
           r.os_image_url r.os_image_sha256 r.os_format)
    | Ok (other, _) ->
      Logs.err (fun m -> m "Expected a provisioning_profile, got %s"
                  (kind_label other));
      exit 1

let run_provision_push () =
  if !provision_mac = "" then begin
    Logs.err (fun m -> m "Missing --mac argument.");
    exit 1
  end;
  match !manifest_files with
  | [] ->
    Logs.err (fun m -> m "Provide a provisioning_profile manifest as argument.");
    exit 1
  | path :: _ ->
    let fpath = Fpath.v path in
    match Hamac_provisioning.Manifest_parser.load_file fpath with
    | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
    | Ok (Hamac_provisioning.Manifest_types.MProvisioningProfile profile, _) ->
      let extra = if !provision_bundles_dir = ""
        then [] else [Fpath.v !provision_bundles_dir]
      in
      (match Hamac_provisioning.Provisioning_gen.render ~extra_search_paths:extra profile with
       | Error e ->
         Logs.err (fun m -> m "%a" Hamac_provisioning.Provisioning_gen.pp_error e);
         exit 1
       | Ok r ->
         match Provisioning_client.push
                 ~discovery_url:!provision_discovery_url
                 ~mac:!provision_mac r with
         | Ok () ->
           Logs.app (fun m -> m "Pushed profile '%s' for MAC %s to %s"
                       r.profile_name !provision_mac !provision_discovery_url)
         | Error e ->
           Logs.err (fun m -> m "%a" Provisioning_client.pp_push_error e);
           exit 1)
    | Ok (other, _) ->
      Logs.err (fun m -> m "Expected a provisioning_profile, got %s"
                  (kind_label other));
      exit 1

let run_provision_clear () =
  if !provision_mac = "" then begin
    Logs.err (fun m -> m "Missing --mac argument.");
    exit 1
  end;
  match Provisioning_client.delete
          ~discovery_url:!provision_discovery_url ~mac:!provision_mac with
  | Ok () ->
    Logs.app (fun m -> m "Cleared profile for MAC %s on %s"
                !provision_mac !provision_discovery_url)
  | Error e ->
    Logs.err (fun m -> m "%a" Provisioning_client.pp_push_error e);
    exit 1

(* ============================================================ *)
(* CLI (cmdliner)                                               *)
(* ============================================================ *)

open Cmdliner

let set_debug d = if d then Logs.set_level (Some Logs.Debug)

(* ---- Arguments partagés ---- *)

let files_arg =
  let doc = "Manifest files (.sieste.yml)." in
  Arg.(value & pos_all string [] & info [] ~docv:"FILES" ~doc)

let debug_arg =
  let doc = "Enable debug mode." in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let seed_arg =
  let doc =
    "Seed the credential generator, so that resolving the same manifests twice \
     yields the same credentials. Test and demo aid: seeded credentials are \
     predictable. Never use it for a real deployment."
  in
  Arg.(value & opt (some int) None & info ["seed"] ~docv:"N" ~doc)

let bundles_dir_arg =
  let doc =
    "Extra directory to search for bundles (prepended to default search path)."
  in
  Arg.(value & opt string "" & info ["bundles-dir"] ~docv:"DIR" ~doc)

let profile_arg =
  let doc = "Provisioning profile manifest (.yaml). Required." in
  Arg.(value & opt string "" & info ["profile"] ~docv:"FILE" ~doc)

let mac_arg =
  let doc = "Target MAC address (lowercased automatically). Required." in
  Arg.(value & opt string "" & info ["mac"] ~docv:"MAC" ~doc)

let discovery_arg =
  let doc = "Discovery server base URL (no trailing slash)." in
  Arg.(value & opt string "http://localhost:8877" & info ["discovery"] ~docv:"URL" ~doc)

(* ---- Termes / commandes ---- *)

(* Commandes qui consomment les fichiers positionnels + debug. *)
let files_term run =
  let go files debug = manifest_files := files; set_debug debug; run () in
  Term.(const go $ files_arg $ debug_arg)

(* Commandes qui génèrent des credentials : mêmes arguments, plus --seed. *)
let files_seed_term run =
  let go files seed debug =
    manifest_files := files;
    set_debug debug;
    (match seed with
     | Some s ->
       Resolver.set_seed s;
       Logs.warn (fun m ->
         m "--seed %d: generated credentials are reproducible, hence \
            predictable. Never use this for a real deployment." s)
     | None -> ());
    run ()
  in
  Term.(const go $ files_arg $ seed_arg $ debug_arg)

let validate_term = files_term run_validate
let validate_cmd =
  Cmd.v (Cmd.info "validate" ~doc:"Validate manifest files.") validate_term
let plan_cmd =
  Cmd.v (Cmd.info "plan" ~doc:"Plan infrastructure from service manifests.")
    (files_term run_plan)
let resolve_cmd =
  Cmd.v (Cmd.info "resolve"
           ~doc:"Resolve service dependencies to concrete providers.")
    (files_seed_term run_resolve)
let simulate_cmd =
  Cmd.v (Cmd.info "simulate"
           ~doc:"Simulate infrastructure with DinD nodes and zone isolation.")
    (files_seed_term run_simulate)
let deploy_cmd =
  Cmd.v (Cmd.info "deploy"
           ~doc:"Generate flat docker-compose.yml from resolved stack.")
    (files_seed_term run_deploy)

let status_cmd =
  let go debug = set_debug debug; run_status () in
  Cmd.v (Cmd.info "status" ~doc:"Show stack status.")
    Term.(const go $ debug_arg)

let provision_dryrun_cmd =
  let go profile bundles_dir debug =
    set_debug debug;
    if profile <> "" then manifest_files := [profile];
    provision_bundles_dir := bundles_dir;
    run_provision_dryrun ()
  in
  Cmd.v (Cmd.info "provision-dryrun"
           ~doc:"Render cloud-init + iPXE for a provisioning_profile without pushing it.")
    Term.(const go $ profile_arg $ bundles_dir_arg $ debug_arg)

let provision_push_cmd =
  let go profile bundles_dir mac discovery debug =
    set_debug debug;
    if profile <> "" then manifest_files := [profile];
    provision_bundles_dir := bundles_dir;
    provision_mac := mac;
    provision_discovery_url := discovery;
    run_provision_push ()
  in
  Cmd.v (Cmd.info "provision-push"
           ~doc:"Render and push a provisioning_profile to the discovery server for a MAC.")
    Term.(const go $ profile_arg $ bundles_dir_arg $ mac_arg $ discovery_arg $ debug_arg)

let provision_clear_cmd =
  let go mac discovery debug =
    set_debug debug;
    provision_mac := mac;
    provision_discovery_url := discovery;
    run_provision_clear ()
  in
  Cmd.v (Cmd.info "provision-clear"
           ~doc:"Remove the provisioning record for a MAC on the discovery server.")
    Term.(const go $ mac_arg $ discovery_arg $ debug_arg)

let main_cmd =
  let doc = "Hamac - stack manager for SIESTE manifests." in
  Cmd.group (Cmd.info "hamac" ~doc)
    [ validate_cmd; plan_cmd; resolve_cmd; simulate_cmd; deploy_cmd; status_cmd;
      provision_dryrun_cmd; provision_push_cmd; provision_clear_cmd ]

let () =
  Printexc.record_backtrace true;
  Logs.set_reporter (Logs_fmt.reporter ());
  Logs.set_level (Some Logs.Warning);
  let code =
    try Cmd.eval main_cmd
    with e ->
      Fmt.epr "%s@.%s@." (Printexc.to_string e) (Printexc.get_backtrace ());
      2
  in
  exit code
