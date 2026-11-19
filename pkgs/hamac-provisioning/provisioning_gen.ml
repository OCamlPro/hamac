(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Générateur de cloud-init / iPXE à partir d'un [provisioning_profile].

    Pipeline :
    1. Pour chaque [bundle_ref] du profil, charger [bundle.loaf] et le snippet
       cloud-init Jinja2, le rendre avec les paramètres fournis.
    2. Merger tous les fragments cloud-init + [cloud_init_extra] du profil.
    3. Émettre le YAML final préfixé par [#cloud-config] et un script iPXE
       minimal pointant vers l'OS image.

    Cf. [doc/typst/provisioning.typ]. *)

open Hamac_manifest.Types

(* ============================================================ *)
(* Erreurs                                                       *)
(* ============================================================ *)

type error =
  | Bundle_not_found of string * string list (* nom, paths essayés *)
  | Bundle_parse_error of string * string    (* nom, message *)
  | Missing_required_param of string * string (* bundle, param *)
  | Template_render_error of string * string  (* fichier, message *)
  | Script_not_found of string * string       (* bundle, script path *)
  | Write_files_collision of string * string * string (* chemin, deux origines *)
  | Missing_preseed_param of string * string  (* profil, param machine requis pour netinstall *)

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
  | Write_files_collision (path, a, b) ->
    Format.fprintf fmt "write_files : %s et %s écrivent tous deux '%s' avec des contenus différents"
      a b path
  | Missing_preseed_param (profile, p) ->
    Format.fprintf fmt
      "profile '%s' (format netinstall) : paramètre machine requis '%s' manquant \
       (luks_passphrase est obligatoire pour le chiffrement LUKS2 du disque)"
      profile p

(* ============================================================ *)
(* Résultat                                                      *)
(* ============================================================ *)

type rendered_profile = {
  profile_name: string;
  cloud_init: string;       (** YAML final, préfixé par #cloud-config *)
  ipxe_script: string;      (** Script iPXE pointant vers l'OS image *)
  preseed: string;          (** preseed d-i (format netinstall), "" sinon *)
  os_image_url: string;
  os_image_sha256: string;
  os_format: string;
  os_raw_zst_url: string;      (** "" si absent, cf. os_image_spec *)
  os_raw_zst_sha256: string;
  os_bmap_url: string;
}

(* ============================================================ *)
(* Conversion des paramètres → Jingoo.Jg_types.tvalue                   *)
(* ============================================================ *)

(** Conversion d'une valeur de paramètre (bundle_ref) en valeur jingoo. *)
let rec param_to_jg (v : param_value) : Jingoo.Jg_types.tvalue =
  match v with
  | PNull -> Jingoo.Jg_types.Tnull
  | PBool b -> Jingoo.Jg_types.Tbool b
  | PInt i -> Jingoo.Jg_types.Tint i
  | PFloat f -> Jingoo.Jg_types.Tfloat f
  | PString s -> Jingoo.Jg_types.Tstr s
  | PList items -> Jingoo.Jg_types.Tlist (List.map param_to_jg items)
  | PObject fields ->
    Jingoo.Jg_types.Tobj (List.map (fun (k, v) -> (k, param_to_jg v)) fields)

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

(** Charge le manifeste [bundle.loaf] d'un répertoire de bundle, seul : un
    bundle qui en nomme d'autres par [depends_on] se charge avec eux, dans
    l'ensemble de fichiers du profil (cf. {!bundle_loaf_files}). *)
let load_bundle_manifest (dir : Fpath.t) : (bundle_manifest, string) Stdlib.result =
  let file = Fpath.(dir / "bundle.loaf") in
  match Hamac_manifest.Stack_check.load_files [Fpath.to_string file] with
  | Error msg -> Error msg
  | Ok ([_, MBundle b], _) -> Ok b
  | Ok _ -> Error (Printf.sprintf "%s : pas un manifeste de bundle" (Fpath.to_string file))

(* ============================================================ *)
(* Validation des params                                         *)
(* ============================================================ *)

(** Vérifie que tous les params requis du bundle sont fournis par le bundle_ref. *)
let check_required_params (b : bundle_manifest) (ref_params : (string * param_value) list)
  : (unit, error) Stdlib.result =
  let rec aux = function
    | [] -> Ok ()
    | (p : bundle_param_spec) :: rest ->
      if p.param_required && not (List.mem_assoc p.param_name ref_params) then
        Error (Missing_required_param (b.bdl_name, p.param_name))
      else aux rest
  in
  aux b.bdl_params

(** Les paramètres sous le type que le bundle leur déclare : un profil écrit
    un booléen comme la constante [true] ou [false], que la lecture du
    profil, sans le bundle, garde en chaîne. *)
let typed_params (b : bundle_manifest) (params : (string * param_value) list) =
  List.map (fun (name, v) ->
    match List.find_opt (fun (p : bundle_param_spec) -> p.param_name = name) b.bdl_params, v with
    | Some { param_type = "bool"; _ }, PString "true" -> (name, PBool true)
    | Some { param_type = "bool"; _ }, PString "false" -> (name, PBool false)
    | _ -> (name, v)) params

(* ============================================================ *)
(* Rendu Jinja2 d'un fichier                                     *)
(* ============================================================ *)

let render_file ~(file : Fpath.t) ~(params : (string * param_value) list)
  : (string, error) Stdlib.result =
  let file_str = Fpath.to_string file in
  match Bos.OS.File.read file with
  | Error (`Msg msg) -> Error (Template_render_error (file_str, msg))
  | Ok content ->
    try
      let models = [("params", param_to_jg (PObject params))] in
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

(** Deux fragments (nommés par leur origine) qui écrivent le même chemin
    par [write_files] avec des entrées différentes : la concaténation
    garderait les deux, et cloud-init écrirait l'une sur l'autre. La même
    entrée deux fois est admise. *)
let write_files_collision (fragments : (string * Yaml.value) list) =
  let entries = List.concat_map (fun (origin, v) ->
    match v with
    | `O fields ->
      (match List.assoc_opt "write_files" fields with
       | Some (`A items) ->
         List.filter_map (function
           | `O f as entry ->
             (match List.assoc_opt "path" f with
              | Some (`String path) -> Some (path, origin, entry)
              | _ -> None)
           | _ -> None) items
       | _ -> [])
    | _ -> []) fragments in
  let rec find = function
    | [] -> None
    | (path, origin, entry) :: rest ->
      match List.find_opt (fun (p, o, e) -> p = path && o <> origin && e <> entry) rest with
      | Some (_, other, _) -> Some (Write_files_collision (path, origin, other))
      | None -> find rest in
  find entries

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
  let base = Filename.dirname os.os_url in
  let lines = [
    "#!ipxe";
    "# Généré par hamac (provisioning_gen)";
    Printf.sprintf "# Image: %s (%s)" os.os_image_name os.os_format;
    "";
    "set base-url " ^ base;
  ] @ (if os.os_format = "netinstall" then
      (* répertoire netboot d-i : noyau 'linux' + initrd 'initrd.gz' *)
      [ Printf.sprintf "kernel %s/linux" base;
        Printf.sprintf "initrd %s/initrd.gz" base;
        "boot" ]
    else
      [ Printf.sprintf "kernel %s/vmlinuz initrd=initrd.img boot=live components" base;
        Printf.sprintf "initrd %s/initrd.img" base;
        "boot" ]) in
  String.concat "\n" lines ^ "\n"

(* ============================================================ *)
(* Preseed (format os netinstall)                                *)
(* ============================================================ *)

(** Valeur texte d'un paramètre machine (PString direct, sinon rendering
    scalaire). *)
let param_str (params : (string * param_value) list) (name : string) : string option =
  match List.assoc_opt name params with
  | Some (PString s) -> Some s
  | Some (PInt i) -> Some (string_of_int i)
  | Some (PBool b) -> Some (string_of_bool b)
  | _ -> None

(** Échappe une valeur pour une ligne de preseed d-i (les backslashes de
    continuation de ligne ne doivent pas apparaître dans les valeurs). *)
let preseed_escape s =
  String.concat " " (String.split_on_char '\n' s)

(** Preseed d-i pour le format [netinstall] : installation automatisée avec
    plein disque chiffré LUKS2 (partman-crypto), déverrouillage par TPM2
    (systemd-cryptenroll, PCR 7+11) et, si le paramètre machine [tang_url]
    est fourni, binding Clevis/Tang pour le déverrouillage à distance via le
    réseau d'administration ; repli sur la passphrase LUKS2
    ([luks_passphrase], paramètre machine obligatoire).

    Le seed cloud-init NoCloud est déposé dans le système installé ; il est
    servi par le discovery à [<base>/provisioning/<mac>/cloud-init], d'où
    [~public_base_url] et [~machine_mac] (chaînes vides = on saute le dépôt
    du seed, ex. dry-run hors discovery).

    Les lignes [profile.pp_preseed_extra] sont ajoutées telles quelles à la
    fin. Le disque cible ([partman-auto/disk]) n'est PAS ici : il est passé
    sur la ligne de commande du noyau par l'init PXE (qui connaît le disque),
    comme [preseed/url]. *)
let render_preseed (profile : provisioning_profile_manifest)
    ~(params : (string * param_value) list)
    ~(public_base_url : string) ~(machine_mac : string) : (string, error) Stdlib.result =
  let ( let* ) = Stdlib.Result.bind in
  let os = profile.pp_os in
  if os.os_format <> "netinstall" then Ok ""
  else begin
    let* luks_passphrase =
      match param_str params "luks_passphrase" with
      | Some p when p <> "" -> Ok p
      | _ -> Error (Missing_preseed_param (profile.pp_name, "luks_passphrase")) in
    let tang_url = param_str params "tang_url" |> Option.value ~default:"" in
    let username = param_str params "username" |> Option.value ~default:"debian" in
    let full_name = param_str params "full_name" |> Option.value ~default:username in
    let initial_password = param_str params "initial_password" |> Option.value ~default:"" in
    let hostname =
      match param_str params "hostname" with
      | Some h when h <> "" -> h
      | _ -> "hamac-" ^ (if machine_mac = "" then "node" else
                           String.concat "-" (String.split_on_char ':' machine_mac)) in
    let esc = preseed_escape in
    let seed_lines =
      if public_base_url <> "" && machine_mac <> "" then
        let base = String.trim public_base_url in
        let base = if String.ends_with ~suffix:"/" base then String.sub base 0 (String.length base - 1) else base in
        [ "   mkdir -p /target/var/lib/cloud/seed/nocloud; \\";
          Printf.sprintf "   wget -q -O /target/var/lib/cloud/seed/nocloud/user-data %s/provisioning/%s/cloud-init; \\" base machine_mac;
          Printf.sprintf "   printf 'instance-id: hamac-%s\\nlocal-hostname: %s\\n' > /target/var/lib/cloud/seed/nocloud/meta-data"
            (String.concat "-" (String.split_on_char ':' machine_mac)) (esc hostname) ]
      else [] in
    let clevis_line =
      if tang_url = "" then []
      else
        [ "   echo '" ^ esc luks_passphrase ^ "' | in-target clevis luks bind -y -k - -d \"$LUKSDEV\" tang '{\"url\":\"" ^ esc tang_url ^ "\"}' ; \\" ] in
    let lines = [
      "# Preseed généré par hamac (provisioning_gen) pour le profil '" ^ profile.pp_name ^ "'";
      "# Format netinstall : installation d-i automatisée, plein disque chiffré LUKS2.";
      "# Régénéré à chaque push de la machine — ne pas éditer à la main.";
      "d-i debian-installer/language string fr";
      "d-i debian-installer/country string FR";
      "d-i debian-installer/locale string fr_FR.UTF-8";
      "d-i keyboard-configuration/xkb-keymap select fr";
      "d-i netcfg/enable boolean true";
      "d-i netcfg/choose_interface select auto";
      Printf.sprintf "d-i netcfg/get_hostname string %s" (esc hostname);
      "d-i netcfg/get_domain string intranet";
      "d-i mirror/country string manual";
      "d-i mirror/http/hostname string deb.debian.org";
      "d-i mirror/http/directory string /debian";
      "d-i mirror/http/proxy string";
      "d-i clock-setup/utc boolean true";
      "d-i time/zone string Europe/Paris";
      "d-i clock-setup/ntp boolean true";
      "";
      "# Compte créé par d-i avec les paramètres machine ; le bundle cloud-init";
      "# le reprend au premier boot (sudo, clés SSH, mot de passe expiré).";
      "d-i passwd/root-login boolean false";
      Printf.sprintf "d-i passwd/user-fullname string %s" (esc full_name);
      Printf.sprintf "d-i passwd/username string %s" (esc username);
      Printf.sprintf "d-i passwd/user-password password %s" (esc initial_password);
      Printf.sprintf "d-i passwd/user-password-again password %s" (esc initial_password);
      "d-i user-setup/allow-password-weak boolean true";
      "d-i user-setup/encrypt-home boolean false";
      "";
      "# Disque : plein disque chiffré LUKS2 (partman-crypto, sans LVM).";
      "# Le disque cible (partman-auto/disk) et preseed/url sont passés sur la";
      "# ligne de commande du noyau par l'init PXE.";
      "d-i partman-auto/method string crypto";
      "d-i partman-auto/expert_recipe string \\";
      "   hamac-crypto :: \\";
      "      512 512 1024 free \\";
      "         $primary{ } $bootable{ } method{ efi } format{ efi } . \\";
      "      100% 1000% -1 ext4 \\";
      "         $primary{ } method{ crypto } format{ } . \\";
      "      100% 1000% -1 ext4 \\";
      "         $crypto{ } method{ format } format{ } \\";
      "         use_filesystem{ } filesystem{ ext4 } mountpoint{ / } .";
      "d-i partman-crypto/confirm boolean true";
      Printf.sprintf "d-i partman-crypto/passphrase password %s" (esc luks_passphrase);
      Printf.sprintf "d-i partman-crypto/passphrase-again password %s" (esc luks_passphrase);
      "d-i partman-partitioning/confirm_write_new_label boolean true";
      "d-i partman/choose_partition select finish";
      "d-i partman/confirm boolean true";
      "d-i partman/confirm_nooverwrite boolean true";
      "";
      "# Paquets : déverrouillage LUKS2 par TPM2 (PCR 7+11) et Clevis/Tang, + cloud-init.";
      "d-i pkgsel/include string openssh-server cryptsetup-initramfs clevis clevis-luks clevis-initramfs cloud-init";
      "d-i pkgsel/upgrade select none";
      "";
      "# Enregistrement des slots de déverrouillage + seed cloud-init NoCloud.";
      "d-i preseed/late_command string \\";
      "   LUKSDEV=$(in-target sh -c 'blkid -o device -t TYPE=crypto_LUKS | head -n1'); \\";
      "   printf '%s' '" ^ esc luks_passphrase ^ "' | in-target systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7+11 --key-file=- \"$LUKSDEV\"; \\";
    ] @ clevis_line @ seed_lines @ [
      "   true";
      "";
      "d-i finish-install/keep-consoles boolean true";
    ] @ List.map (fun l -> l) profile.pp_preseed_extra in
    Ok (String.concat "\n" lines ^ "\n")
  end

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

(** Les fichiers [bundle.loaf] des bundles de [search_paths] : un profil
    LOAF se charge avec eux, puisqu'il nomme ses bundles (le premier
    répertoire où un bundle apparaît l'emporte, comme pour
    {!find_bundle_dir}). *)
let bundle_loaf_files ~(search_paths : Fpath.t list) : string list =
  let seen = Hashtbl.create 16 in
  List.concat_map (fun base ->
    let b = Fpath.to_string base in
    if not (Sys.file_exists b && Sys.is_directory b) then []
    else
      Sys.readdir b |> Array.to_list |> List.sort compare
      |> List.filter_map (fun name ->
        let file = Filename.concat (Filename.concat b name) "bundle.loaf" in
        if Hashtbl.mem seen name || not (Sys.file_exists file) then None
        else (Hashtbl.add seen name (); Some file)))
    search_paths

(** Génère un cloud-init et un script iPXE pour un profil donné.

    [extra_search_paths] est prépendé à la liste de recherche des bundles.
    [bundles] : manifestes de bundles déjà chargés (ceux de l'ensemble de
    fichiers LOAF du profil), préférés à ceux des répertoires de bundle, où
    restent cherchés les gabarits. *)
let render
    ?(extra_search_paths : Fpath.t list = [])
    ?(bundles : bundle_manifest list = [])
    ?(machine_params : (string * param_value) list = [])
    ?(public_base_url : string = "")
    ?(machine_mac : string = "")
    (profile : provisioning_profile_manifest)
  : (rendered_profile, error) Stdlib.result =
  let ( let* ) = Stdlib.Result.bind in
  let search_paths = extra_search_paths @ default_search_paths () in
  (* Paramètres vus par le preseed : params machine (prioritaires) + params
     des bundle_ref du profil (pour un dry-run CLI hors discovery). *)
  let profile_params =
    List.concat_map (fun (br : bundle_ref) -> br.bundle_params) profile.pp_bundles in
  let preseed_params =
    machine_params @ List.filter (fun (k, _) -> not (List.mem_assoc k machine_params)) profile_params in

  let os_family = profile.pp_os.os_family in

  (* Pour chaque bundle_ref, sélectionner le template cloud-init de la
     bonne famille d'OS, le rendre avec les params, et retourner le
     Yaml.value (le merge inter-bundles se fait après). *)
  let process_bundle_ref (br : bundle_ref) : (Yaml.value, error) Stdlib.result =
    (* 1. Trouver le bundle *)
    let bundle_dir = match find_bundle_dir ~search_paths br.bundle_name with
      | Some d -> Ok d
      | None ->
        Error (Bundle_not_found
                 (br.bundle_name, List.map Fpath.to_string search_paths))
    in
    let* bundle_dir = bundle_dir in

    (* 2. Le manifeste du bundle : déjà chargé, sinon le bundle.loaf de
          son répertoire *)
    let* b = (match List.find_opt (fun b -> b.bdl_name = br.bundle_name) bundles with
              | Some b -> Ok b
              | None ->
                match load_bundle_manifest bundle_dir with
                | Ok b -> Ok b
                | Error msg -> Error (Bundle_parse_error (br.bundle_name, msg))) in

    (* 3. Vérifier params requis *)
    let* () = check_required_params b br.bundle_params in

    (* 4. Sélection du template cloud-init selon la famille d'OS :
          cloud-init.<family>.yaml.j2 en priorité, sinon le portable
          cloud-init.yaml.j2. Erreur si aucun ne convient. *)
    let family_tpl = Fpath.(bundle_dir / Printf.sprintf "cloud-init.%s.yaml.j2" os_family) in
    let default_tpl = Fpath.(bundle_dir / "cloud-init.yaml.j2") in
    let exists p = Sys.file_exists (Fpath.to_string p) in
    let* tpl_path =
      if exists family_tpl then Ok family_tpl
      else if exists default_tpl then Ok default_tpl
      else
        Error (Bundle_parse_error
                 (br.bundle_name,
                  Printf.sprintf
                    "no cloud-init template for family '%s' (looked for %s and %s)"
                    os_family
                    (Fpath.to_string family_tpl) (Fpath.to_string default_tpl)))
    in

    (* 5. Rendre le template avec les params, puis parser en Yaml.value *)
    let* tpl_str = render_file ~file:tpl_path ~params:(typed_params b br.bundle_params) in
    (match parse_snippet tpl_str with
     | Ok v -> Ok v
     | Error m -> Error (Template_render_error (Fpath.to_string tpl_path, m)))
  in

  let rec process_all acc = function
    | [] -> Ok (List.rev acc)
    | br :: rest ->
      let* y = process_bundle_ref br in
      process_all (y :: acc) rest
  in
  let* bundle_yamls = process_all [] profile.pp_bundles in

  (* Merge bundles + cloud_init_extra, dans l'ordre du profil *)
  let* extra = match profile.pp_cloud_init_extra with
    | None -> Ok []
    | Some src ->
      match parse_snippet src with
      | Ok v -> Ok [v]
      | Error m -> Error (Template_render_error ("cloud_init_extra", m)) in
  let all_fragments = bundle_yamls @ extra in
  let origins =
    List.map (fun (br : bundle_ref) -> "le bundle " ^ br.bundle_name) profile.pp_bundles
    @ List.map (fun _ -> "cloud_init_extra") extra in
  let* () = match write_files_collision (List.combine origins all_fragments) with
    | Some e -> Error e
    | None -> Ok () in
  let merged = dedup_packages (merge_many all_fragments) in

  (* Sérialiser *)
  let yaml_str = match Yaml.to_string merged with
    | Ok s -> s
    | Error (`Msg m) -> failwith ("internal: échec sérialisation YAML : " ^ m)
  in
  let cloud_init = "#cloud-config\n# Généré par hamac pour le profile '"
                   ^ profile.pp_name ^ "'\n" ^ yaml_str in
  let ipxe_script = render_ipxe profile.pp_os in
  let* preseed = render_preseed profile ~params:preseed_params
                   ~public_base_url ~machine_mac in
  Ok {
    profile_name = profile.pp_name;
    cloud_init;
    ipxe_script;
    preseed;
    os_image_url = profile.pp_os.os_url;
    os_image_sha256 = profile.pp_os.os_sha256;
    os_format = profile.pp_os.os_format;
    os_raw_zst_url = profile.pp_os.os_raw_zst_url;
    os_raw_zst_sha256 = profile.pp_os.os_raw_zst_sha256;
    os_bmap_url = profile.pp_os.os_bmap_url;
  }
