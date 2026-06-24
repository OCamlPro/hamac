(** Provider registry for hamac.

    Loads provider manifests from a search path and indexes them
    by name and capability for resolution. *)

open Hamac_provisioning.Manifest_types

type t = {
  by_name: (string, service_manifest) Hashtbl.t;
  by_capability: (string, service_manifest) Hashtbl.t;
}

let create () = {
  by_name = Hashtbl.create 16;
  by_capability = Hashtbl.create 16;
}

(** Register a provider manifest *)
let register (registry : t) (provider : service_manifest) =
  Hashtbl.replace registry.by_name provider.name provider;
  match provider.capability with
  | Some cap -> Hashtbl.replace registry.by_capability cap provider
  | None -> ()

(** Find a provider by exact name *)
let find_by_name (registry : t) (name : string) : service_manifest option =
  Hashtbl.find_opt registry.by_name name

(** Find a provider by capability *)
let find_by_capability (registry : t) (cap : string) : service_manifest option =
  Hashtbl.find_opt registry.by_capability cap

(** Resolve a provider: first try by name, then by capability *)
let resolve (registry : t) ~(provider_name : string option) ~(capability : string option) : service_manifest option =
  match provider_name with
  | Some name ->
    (match find_by_name registry name with
     | Some _ as r -> r
     | None ->
       (* Maybe the name IS the capability *)
       find_by_capability registry name)
  | None ->
    match capability with
    | Some cap -> find_by_capability registry cap
    | None -> None

(** Load all .sieste.yml files from a directory into the registry *)
let load_dir (registry : t) (dir : Fpath.t) : (int, string) result =
  match Bos.OS.Dir.exists dir with
  | Error (`Msg msg) -> Error msg
  | Ok false -> Ok 0
  | Ok true ->
    match Bos.OS.Dir.contents dir with
    | Error (`Msg msg) -> Error msg
    | Ok paths ->
      let count = ref 0 in
      List.iter (fun path ->
        let ext = Fpath.get_ext path in
        if ext = ".yml" || ext = ".yaml" then begin
          match Hamac_provisioning.Manifest_parser.load_file path with
          | Ok (MService svc, _warnings) when svc.capability <> None ->
            register registry svc;
            incr count;
            Logs.debug (fun m -> m "Loaded provider: %s (capability=%s)"
              svc.name (Option.value ~default:"?" svc.capability))
          | Ok (MService svc, _) ->
            (* Service without capability — still register by name *)
            register registry svc;
            incr count;
            Logs.debug (fun m -> m "Loaded provider: %s (no capability)" svc.name)
          | Ok _ ->
            Logs.debug (fun m -> m "Skipping non-service manifest: %a" Fpath.pp path)
          | Error msg ->
            Logs.warn (fun m -> m "Skipping invalid provider %a: %s" Fpath.pp path msg)
        end
      ) paths;
      Ok !count

(** Load from default search paths *)
let load_defaults (registry : t) : unit =
  let search_paths = [
    Fpath.v "./providers";
    Fpath.v "./sieste-providers";
  ] in
  (* Add ~/.hamac/providers if HOME is set *)
  let search_paths = match Sys.getenv_opt "HOME" with
    | Some home -> search_paths @ [Fpath.(v home / ".hamac" / "providers")]
    | None -> search_paths
  in
  List.iter (fun dir ->
    match load_dir registry dir with
    | Ok 0 -> ()
    | Ok n -> Logs.app (fun m -> m "Loaded %d provider(s) from %a" n Fpath.pp dir)
    | Error msg -> Logs.debug (fun m -> m "Cannot load providers from %a: %s" Fpath.pp dir msg)
  ) search_paths

let all_providers (registry : t) : service_manifest list =
  Hashtbl.fold (fun _name svc acc -> svc :: acc) registry.by_name []
