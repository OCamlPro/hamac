(** Générateur de cloud-init / iPXE à partir d'un [provisioning_profile].

    Pipeline :
    1. Pour chaque [bundle_ref] du profil, charger [bundle.yaml] et le snippet
       cloud-init Jinja2, le rendre avec les paramètres fournis.
    2. Pour chaque script post_install, le rendre Jinja2 et préparer son
       injection dans le cloud-init via [write_files] + [runcmd].
    3. Merger tous les fragments cloud-init + [cloud_init_extra] du profil.
    4. Émettre le YAML final préfixé par [#cloud-config] et un script iPXE
       minimal pointant vers l'OS image.

    Cf. [doc/PROVISIONING_SPEC.md]. *)

open Manifest_types

(* ============================================================ *)
(* Erreurs                                                       *)
(* ============================================================ *)

type error =
  | Bundle_not_found of string * string list (* nom, paths essayés *)
  | Bundle_parse_error of string * string    (* nom, message *)
  | Missing_required_param of string * string (* bundle, param *)
  | Template_render_error of string * string  (* fichier, message *)
  | Script_not_found of string * string       (* bundle, script path *)

let pp_error fmt = function
  | Bundle_not_found (name, paths) ->
    Format.fprintf fmt "bundle '%s' introuvable, cherché dans : %s"
      name (String.concat ", " paths)
  | Bundle_parse_error (name, msg) ->
    Format.fprintf fmt "bundle '%s' : %s" name msg
  | Missing_required_param (bundle, p) ->
    Format.fprintf fmt "bundle '%s' : paramètre requis '%s' manquant" bundle p
  | Template_render_error (file, msg) ->
    Format.fprintf fmt "rendu Jinja2 '%s' : %s" file msg
  | Script_not_found (bundle, path) ->
    Format.fprintf fmt "bundle '%s' : script '%s' introuvable" bundle path

(* ============================================================ *)
(* Résultat                                                      *)
(* ============================================================ *)

type rendered_profile = {
  profile_name: string;
  cloud_init: string;       (** YAML final, préfixé par #cloud-config *)
  ipxe_script: string;      (** Script iPXE pointant vers l'OS image *)
  os_image_url: string;
  os_image_sha256: string;
  os_format: string;
}

(* ============================================================ *)
(* Conversion Yaml.value → Jingoo.Jg_types.tvalue                       *)
(* ============================================================ *)

(** Conversion d'une valeur YAML (params du bundle_ref) en valeur jingoo. *)
let rec yaml_to_jg (v : Yaml.value) : Jingoo.Jg_types.tvalue =
  match v with
  | `Null -> Jingoo.Jg_types.Tnull
  | `Bool b -> Jingoo.Jg_types.Tbool b
  | `Float f ->
    if Float.is_integer f then Jingoo.Jg_types.Tint (int_of_float f)
    else Jingoo.Jg_types.Tfloat f
  | `String s -> Jingoo.Jg_types.Tstr s
  | `A items -> Jingoo.Jg_types.Tlist (List.map yaml_to_jg items)
  | `O fields ->
    Jingoo.Jg_types.Tobj (List.map (fun (k, v) -> (k, yaml_to_jg v)) fields)

(* ============================================================ *)
(* Chargement d'un bundle depuis le filesystem                   *)
(* ============================================================ *)

(** Cherche un bundle dans les répertoires donnés. Retourne le path racine
    du bundle ou [None]. *)
let find_bundle_dir ~(search_paths : Fpath.t list) (name : string)
  : Fpath.t option =
  List.find_map (fun base ->
    let dir = Fpath.( / ) base name in
    let s = Fpath.to_string dir in
    if Sys.file_exists s && Sys.is_directory s then Some dir
    else None
  ) search_paths

(** Charge [bundle.yaml] depuis un répertoire de bundle. *)
let load_bundle_manifest (dir : Fpath.t) : (bundle_manifest, string) Stdlib.result =
  let manifest_path = Fpath.(dir / "bundle.yaml") in
  match Manifest_parser.load_file manifest_path with
  | Error msg -> Error msg
  | Ok (MBundle b, _) -> Ok b
  | Ok _ -> Error (Printf.sprintf "%s : pas un manifest 'kind: bundle'"
                     (Fpath.to_string manifest_path))

(* ============================================================ *)
(* Validation des params                                         *)
(* ============================================================ *)

(** Vérifie que tous les params requis du bundle sont fournis par le bundle_ref. *)
let check_required_params (b : bundle_manifest) (ref_params : (string * yaml_value) list)
  : (unit, error) Stdlib.result =
  let rec aux = function
    | [] -> Ok ()
    | (p : bundle_param_spec) :: rest ->
      if p.param_required && not (List.mem_assoc p.param_name ref_params) then
        Error (Missing_required_param (b.bdl_name, p.param_name))
      else aux rest
  in
  aux b.bdl_params

(* ============================================================ *)
(* Rendu Jinja2 d'un fichier                                     *)
(* ============================================================ *)

let render_file ~(file : Fpath.t) ~(params : (string * yaml_value) list)
  : (string, error) Stdlib.result =
  let file_str = Fpath.to_string file in
  match Bos.OS.File.read file with
  | Error (`Msg msg) -> Error (Template_render_error (file_str, msg))
  | Ok content ->
    try
      let models = [("params", yaml_to_jg (`O params))] in
      Ok (Jingoo.Jg_template.from_string ~models content)
    with e ->
      Error (Template_render_error (file_str, Printexc.to_string e))

(* ============================================================ *)
(* Parsing du snippet rendu                                      *)
(* ============================================================ *)

(** Parse un fragment YAML rendu en [Yaml.value]. Un fragment vide est traité
    comme [`O []]. *)
let parse_snippet (s : string) : (Yaml.value, string) Stdlib.result =
  let trimmed = String.trim s in
  if trimmed = "" then Ok (`O [])
  else
    match Yaml.of_string trimmed with
    | Ok v -> Ok v
    | Error (`Msg m) -> Error m

(* ============================================================ *)
(* Merge cloud-init                                              *)
(* ============================================================ *)

(** Merge deux fragments cloud-init.
    - Listes (runcmd, packages, etc.) : concaténation
    - Scalaires : le second gagne
    - Objets : merge récursif des clés communes, union des autres *)
let rec merge_yaml (a : Yaml.value) (b : Yaml.value) : Yaml.value =
  match a, b with
  | `Null, x | x, `Null -> x
  | `A xs, `A ys -> `A (xs @ ys)
  | `O fa, `O fb ->
    let keys = List.fold_left (fun acc (k, _) ->
      if List.mem k acc then acc else acc @ [k]
    ) (List.map fst fa) fb in
    `O (List.map (fun k ->
      match List.assoc_opt k fa, List.assoc_opt k fb with
      | Some va, Some vb -> (k, merge_yaml va vb)
      | Some va, None -> (k, va)
      | None, Some vb -> (k, vb)
      | None, None -> (k, `Null)
    ) keys)
  | _, b -> b  (* scalaire : le second l'emporte *)

let merge_many (vs : Yaml.value list) : Yaml.value =
  List.fold_left merge_yaml (`O []) vs

(* ============================================================ *)
(* Déduplication packages                                        *)
(* ============================================================ *)

(** Si le YAML contient une clé [packages], déduplique en conservant l'ordre. *)
let dedup_packages (v : Yaml.value) : Yaml.value =
  match v with
  | `O fields ->
    `O (List.map (fun (k, value) ->
      if k = "packages" then
        match value with
        | `A items ->
          let seen = Hashtbl.create 16 in
          let kept = List.filter (fun item ->
            match item with
            | `String s ->
              if Hashtbl.mem seen s then false
              else (Hashtbl.add seen s (); true)
            | _ -> true
          ) items in
          (k, `A kept)
        | _ -> (k, value)
      else (k, value)
    ) fields)
  | _ -> v

(* ============================================================ *)
(* iPXE script                                                   *)
(* ============================================================ *)

let render_ipxe (os : os_image_spec) : string =
  let lines = [
    "#!ipxe";
    "# Généré par hamac (provisioning_gen)";
    Printf.sprintf "# Image: %s (%s)" os.os_image_name os.os_format;
    "";
    "set base-url " ^ (Filename.dirname os.os_url);
    Printf.sprintf "kernel %s/vmlinuz initrd=initrd.img boot=live components" (Filename.dirname os.os_url);
    Printf.sprintf "initrd %s/initrd.img" (Filename.dirname os.os_url);
    "boot";
  ] in
  String.concat "\n" lines ^ "\n"

(* ============================================================ *)
(* Génération principale                                         *)
(* ============================================================ *)

(** Recherche les bundles dans, par ordre de priorité :
    - le paramètre [search_paths]
    - $HAMAC_BUNDLES_DIR/
    - ./templates/bundles/
    - /usr/share/hamac/bundles/ *)
let default_search_paths () : Fpath.t list =
  let from_env = match Sys.getenv_opt "HAMAC_BUNDLES_DIR" with
    | Some p -> [Fpath.v p]
    | None -> []
  in
  let cwd_local = [Fpath.v "./templates/bundles"] in
  let system = [Fpath.v "/usr/share/hamac/bundles"] in
  from_env @ cwd_local @ system

(** Génère un cloud-init et un script iPXE pour un profil donné.

    [extra_search_paths] est prépendé à la liste de recherche des bundles. *)
let render
    ?(extra_search_paths : Fpath.t list = [])
    (profile : provisioning_profile_manifest)
  : (rendered_profile, error) Stdlib.result =
  let ( let* ) = Stdlib.Result.bind in
  let search_paths = extra_search_paths @ default_search_paths () in

  (* Pour chaque bundle_ref, produire un Yaml.value mergé incluant snippet
     + write_files des scripts post_install + runcmd. *)
  let process_bundle_ref (br : bundle_ref) : (Yaml.value, error) Stdlib.result =
    (* 1. Trouver le bundle *)
    let bundle_dir = match find_bundle_dir ~search_paths br.bundle_name with
      | Some d -> Ok d
      | None ->
        Error (Bundle_not_found
                 (br.bundle_name, List.map Fpath.to_string search_paths))
    in
    let* bundle_dir = bundle_dir in

    (* 2. Charger bundle.yaml *)
    let* b = (match load_bundle_manifest bundle_dir with
              | Ok b -> Ok b
              | Error msg -> Error (Bundle_parse_error (br.bundle_name, msg))) in

    (* 3. Vérifier params requis *)
    let* () = check_required_params b br.bundle_params in

    (* 4. Rendre le snippet principal *)
    let snippet_path = Fpath.(bundle_dir / "cloud-init.snippet.yaml.j2") in
    let* snippet_str = render_file ~file:snippet_path ~params:br.bundle_params in
    let* snippet_yaml = (match parse_snippet snippet_str with
                        | Ok v -> Ok v
                        | Error m -> Error (Template_render_error
                                              (Fpath.to_string snippet_path, m))) in

    (* 5. Rendre chaque post_install et préparer write_files + runcmd *)
    let render_post_install (rel_path : string)
      : ((string * string), error) Stdlib.result =
      (* rel_path est relatif au bundle_dir, ex: "post-install/10-foo.sh" *)
      let abs = Fpath.(bundle_dir // v rel_path) in
      if not (Sys.file_exists (Fpath.to_string abs)) then
        Error (Script_not_found (br.bundle_name, rel_path))
      else
        let* rendered = render_file ~file:abs ~params:br.bundle_params in
        (* Chemin cible dans le système installé *)
        let basename = Filename.basename rel_path in
        let target =
          Printf.sprintf "/etc/sieste/post-install/%s/%s" br.bundle_name basename
        in
        Ok (target, rendered)
    in
    let rec render_all acc = function
      | [] -> Ok (List.rev acc)
      | p :: rest ->
        let* r = render_post_install p in
        render_all (r :: acc) rest
    in
    let* post_install_rendered = render_all [] b.bdl_post_install in

    (* 6. Construire write_files et runcmd pour les post-install *)
    let post_install_writes = List.map (fun (target, content) ->
      `O [
        "path", `String target;
        "permissions", `String "0755";
        "content", `String content;
      ]
    ) post_install_rendered in
    let post_install_runs = List.map (fun (target, _) -> `String target)
                              post_install_rendered in

    (* 7. packages du bundle *)
    let packages_yaml =
      if b.bdl_packages = [] then `O []
      else `O ["packages", `A (List.map (fun p -> `String p) b.bdl_packages)]
    in

    (* 8. Bundle d'extension cloud-init = snippet + write_files + runcmd + packages *)
    let extension = `O [
      "write_files", `A post_install_writes;
      "runcmd", `A post_install_runs;
    ] in
    Ok (merge_many [snippet_yaml; extension; packages_yaml])
  in

  let rec process_all acc = function
    | [] -> Ok (List.rev acc)
    | br :: rest ->
      let* y = process_bundle_ref br in
      process_all (y :: acc) rest
  in
  let* bundle_yamls = process_all [] profile.pp_bundles in

  (* Merge bundles + cloud_init_extra *)
  let all_fragments = bundle_yamls @
    (match profile.pp_cloud_init_extra with
     | Some v -> [v]
     | None -> []) in
  let merged = dedup_packages (merge_many all_fragments) in

  (* Sérialiser *)
  let yaml_str = match Yaml.to_string merged with
    | Ok s -> s
    | Error (`Msg m) -> failwith ("internal: échec sérialisation YAML : " ^ m)
  in
  let cloud_init = "#cloud-config\n# Généré par hamac pour le profile '"
                   ^ profile.pp_name ^ "'\n" ^ yaml_str in
  let ipxe_script = render_ipxe profile.pp_os in
  Ok {
    profile_name = profile.pp_name;
    cloud_init;
    ipxe_script;
    os_image_url = profile.pp_os.os_url;
    os_image_sha256 = profile.pp_os.os_sha256;
    os_format = profile.pp_os.os_format;
  }
