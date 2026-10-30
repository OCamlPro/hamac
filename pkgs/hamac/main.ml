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
  | Hamac_manifest.Types.MService s ->
    Printf.sprintf "service (name=%s, runtime=%s)" s.name s.runtime
  | MStack s ->
    Printf.sprintf "stack (name=%s, %d services)" s.name (List.length s.services)
  | MPattern p ->
    Printf.sprintf "pattern (name=%s, version=%s, %d zones, %d constraints)"
      p.pat_name p.pat_version (List.length p.zones) (List.length p.constraints)
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

(** The manifests of the file arguments: each YAML file on its own, the
    LOAF files as one set. Errors stop the command. *)
let load_manifests () =
  let loaf, yaml = List.partition Hamac_manifest.Stack_check.is_loaf !manifest_files in
  let of_yaml = List.map (fun path ->
    match Hamac_manifest.Parser.load_file (Fpath.v path) with
    | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
    | Ok (m, _) -> (path, m)) yaml in
  let of_loaf = if loaf = [] then [] else
      match Hamac_manifest.Stack_check.load_files loaf with
      | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
      | Ok (ms, _) -> ms in
  of_yaml @ of_loaf

(** In a set of LOAF files, the providers come with the services
    ({!Hamac_manifest.Stack_check.loaf_providers}): they are added to
    [registry], not deployed as services. *)
let split_loaf_providers registry (manifests : (string * Hamac_manifest.Types.manifest) list) =
  let providers = Hamac_manifest.Stack_check.loaf_providers manifests in
  List.filter (fun (f, m) ->
    match m with
    | Hamac_manifest.Types.MService svc
      when Hamac_manifest.Stack_check.is_loaf f && List.mem svc.name providers ->
      Provider_registry.register registry svc;
      false
    | _ -> true) manifests

(** Load services and stack overrides from file arguments *)
let load_services_and_overrides registry =
  let services = ref [] in
  let overrides = ref [] in
  List.iter (fun (path, m) ->
    let fpath = Fpath.v path in
    match m with
    | Hamac_manifest.Types.MService svc ->
      services := svc :: !services
    | Hamac_manifest.Types.MStack stk ->
      (* Extract overrides from stack manifest *)
      List.iter (fun (sref : Hamac_manifest.Types.stack_service_ref) ->
        let svc_overrides = List.map (fun (o : Hamac_manifest.Types.stack_consume_override) ->
          (o.consume_name, o.provider)
        ) sref.consumes_override in
        if svc_overrides <> [] then begin
          (* Use ref_path basename without extension as service name (a
             LOAF stack gives the name itself) *)
          let base = Filename.basename sref.ref_path in
          let name = try Filename.chop_extension base with _ -> base in
          overrides := (name, svc_overrides) :: !overrides
        end
      ) stk.services
    | other ->
      Logs.warn (fun m -> m "%a: got %s (skipping)"
        Fpath.pp fpath (kind_label other))
  ) (split_loaf_providers registry (load_manifests ()));
  (List.rev !services, !overrides)

(** Flows the services declare between each other, checked against the
    zone lattice (no read up). Any invalid declaration stops the command. *)
let checked_flows ?lattice services =
  let flows, errors = Hamac_manifest.Flows.declared ?lattice services in
  List.iter (fun err -> Logs.err (fun m -> m "%s" (Hamac_manifest.Flows.error_to_string err))) errors;
  if errors <> [] then exit 1;
  flows

(* ============================================================ *)
(* Commands                                                      *)
(* ============================================================ *)

(** Report findings: errors as errors, warnings as warnings. Returns
    (errors, warnings). *)
let report (findings : Hamac_manifest.Stack_check.finding list) =
  let module D = Hamac_manifest.Diagnostic in
  List.fold_left (fun (e, w) (file, (d : D.t)) ->
    match d.severity with
    | D.Error -> Logs.err (fun m -> m "%s" (D.to_string_in file d)); (e + 1, w)
    | D.Warning -> Logs.warn (fun m -> m "%s" (D.to_string_in file d)); (e, w + 1))
    (0, 0) findings

let quiet_providers () =
  let registry = Provider_registry.create () in
  Provider_registry.load_defaults ~verbose:false registry;
  Provider_registry.all_providers registry

(** [hamac validate]: stage 1 on every file; stages 2 and 3 as well when a
    stack is among them (its references, patterns, zones, providers and
    flows). *)
let run_validate ~strict () =
  let given = Hamac_manifest.Stack_check.load_all !manifest_files in
  List.iter (fun (l : Hamac_manifest.Stack_check.loaded) ->
    Option.iter (fun m -> Logs.app (fun f -> f "%s: %s" l.file (kind_label m))) l.manifest)
    given;
  let findings =
    if Hamac_manifest.Stack_check.stacks_of given = [] then
      List.concat_map (fun (l : Hamac_manifest.Stack_check.loaded) -> List.map (fun d -> (l.file, d)) l.diags) given
    else
      let _, _, findings = Hamac_manifest.Stack_check.run ~providers:(quiet_providers ()) given in
      findings
  in
  let errors, warnings = report findings in
  if errors > 0 || (strict && warnings > 0) then exit 1

(** [hamac plan]: the given files form a stack (stages 1 to 3), then the
    topology is inferred under the stack's lattice. *)
let run_plan () =
  let given = Hamac_manifest.Stack_check.load_all !manifest_files in
  let ls, lattice, findings = Hamac_manifest.Stack_check.run ~providers:(quiet_providers ()) given in
  let errors = List.filter (fun (_, d) -> Hamac_manifest.Diagnostic.is_error d) findings in
  let _ = report errors in
  if errors <> [] then exit 1;
  let services = List.map snd (Hamac_manifest.Stack_check.deployed_services_of ls) in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;
  let flows, _ = Hamac_manifest.Flows.declared ~lattice services in
  let plan = Planner.plan ~lattice ~name:"stack" ~flows services in
  Planner.display_plan plan

let run_resolve () =
  let registry = load_registry () in
  let services, overrides = load_services_and_overrides registry in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;

  let _flows = checked_flows services in
  let resolution = Resolver.resolve_all ~registry ~services ~overrides () in

  (* Report errors *)
  List.iter (fun err ->
    Logs.err (fun m -> m "%s" err)
  ) resolution.errors;

  (* Report providers to instantiate *)
  if resolution.providers <> [] then begin
    Logs.app (fun m -> m "Providers to instantiate:");
    List.iter (fun (rp : Resolver.resolved_provider) ->
      let image = match rp.provider.Hamac_manifest.Types.artifact with
        | Some a -> a.Hamac_manifest.Types.path
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
      Logs.app (fun m -> m "  %s.%s -> %s%s"
        w.consumer_name w.consume_name (Resolver.target_name w)
        (match w.target with Resolver.Service _ -> " (service)" | _ -> ""));
      List.iter (fun (k, v) ->
        Logs.app (fun m -> m "    inject: %s=%s" k v)
      ) w.injected_env
    ) resolution.wires
  end;

  if resolution.errors <> [] then exit 1

let run_simulate () =
  let registry = load_registry () in
  let services, overrides = load_services_and_overrides registry in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;

  (* Plan infrastructure *)
  let flows = checked_flows services in
  let plan = Planner.plan ~name:"stack" ~flows services in
  Planner.display_plan plan;

  (* Resolve providers; consumed services are reached on their node *)
  let resolution = Resolver.resolve_all ~service_endpoint:Infra_sim.service_endpoint
      ~registry ~services ~overrides () in
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
  let services, overrides = load_services_and_overrides registry in
  if services = [] then begin
    Logs.err (fun m -> m "No service manifests provided.");
    exit 1
  end;

  let _flows = checked_flows services in
  let zones = List.sort_uniq String.compare (List.map Hamac_manifest.Flows.service_zone services) in
  if List.length zones > 1 then
    Logs.warn (fun m -> m "deploy generates a flat docker-compose on a single \
      network: it does not isolate the security zones (%s). Use `hamac \
      simulate` to deploy with zone filtering." (String.concat ", " zones));
  let resolution = Resolver.resolve_all ~registry ~services ~overrides () in

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

(** The profile given to a provisioning command, the bundle search paths
    and the bundles already loaded. A YAML profile is read on its own; a
    LOAF profile with the [bundle.loaf] of the bundle search paths, since it
    names its bundles. *)
let load_profile () =
  let extra = if !provision_bundles_dir = ""
    then [] else [Fpath.v !provision_bundles_dir] in
  match !manifest_files with
  | [] ->
    Logs.err (fun m -> m "Provide a provisioning_profile manifest as argument.");
    exit 1
  | path :: _ when Hamac_manifest.Stack_check.is_loaf path ->
    let module G = Hamac_provisioning.Provisioning_gen in
    let bundle_files = G.bundle_loaf_files
        ~search_paths:(extra @ G.default_search_paths ()) in
    let files = path :: List.filter (fun f -> f <> path) bundle_files in
    (match Hamac_manifest.Stack_check.load_files files with
     | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
     | Ok (ms, _) ->
       let bundles = List.filter_map (function
         | (_, Hamac_manifest.Types.MBundle b) -> Some b | _ -> None) ms in
       match List.find_map (function
         | (f, Hamac_manifest.Types.MProvisioningProfile p) when f = path -> Some p
         | _ -> None) ms with
       | Some profile -> (profile, extra, bundles)
       | None ->
         Logs.err (fun m -> m "%s: expected a provisioning_profile" path);
         exit 1)
  | path :: _ ->
    match Hamac_manifest.Parser.load_file (Fpath.v path) with
    | Error msg -> Logs.err (fun m -> m "%s" msg); exit 1
    | Ok (Hamac_manifest.Types.MProvisioningProfile profile, _) -> (profile, extra, [])
    | Ok (other, _) ->
      Logs.err (fun m -> m "Expected a provisioning_profile, got %s"
                  (kind_label other));
      exit 1

let run_provision_dryrun () =
  let profile, extra, bundles = load_profile () in
  match Hamac_provisioning.Provisioning_gen.render ~extra_search_paths:extra ~bundles profile with
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
      r.os_image_url r.os_image_sha256 r.os_format

let run_provision_push () =
  if !provision_mac = "" then begin
    Logs.err (fun m -> m "Missing --mac argument.");
    exit 1
  end;
  let profile, extra, bundles = load_profile () in
  match Hamac_provisioning.Provisioning_gen.render ~extra_search_paths:extra ~bundles profile with
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
  let doc =
    "Manifest files: YAML (.yml), each read on its own, or LOAF (.loaf), read \
     together as one set with the vocabulary of Hamac (installed with \
     hamac-manifest; $(b,HAMAC_VOCABULARY) names another directory)." in
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
  let doc =
    "Provisioning profile manifest (.yaml, or .loaf: read with the bundle.loaf \
     of the bundle search paths). Required." in
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

let strict_arg =
  let doc = "Fail on warnings too, not only on errors." in
  Arg.(value & flag & info ["strict"] ~doc)

let validate_cmd =
  let go files strict debug =
    set_debug debug;
    manifest_files := files;
    run_validate ~strict ()
  in
  Cmd.v (Cmd.info "validate"
           ~doc:"Validate manifest files (and, for a stack, its references, \
                 patterns, zones, providers and flows).")
    Term.(const go $ files_arg $ strict_arg $ debug_arg)
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
  let doc = "Hamac - infrastructure orchestrator for declarative manifests." in
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
