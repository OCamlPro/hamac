(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** [show.exe [-L DIR]… FILE…] : les valeurs {!Types.manifest} qu'un
    ensemble de fichiers LOAF donne, une par manifeste, dans l'ordre des
    sortes puis des sujets, précédées de leur fichier ; les erreurs sur la
    sortie d'erreur. Le test les fige : c'est ce que le reste de Hamac reçoit
    du chargeur. *)

open Hamac_manifest

let () =
  let rec args lib files = function
    | "-L" :: d :: rest -> args (lib @ [d]) files rest
    | f :: rest -> args lib (files @ [f]) rest
    | [] -> (lib, files) in
  let lib, files = args [] [] (List.tl (Array.to_list Sys.argv)) in
  let sources, diags = Loaf_source.load ~lib files in
  List.iter (fun (f, (d : Diagnostic.t)) ->
    if Diagnostic.is_error d then prerr_endline (Diagnostic.to_string_in f d)) diags;
  List.iter (fun (s : Loaf_source.source) ->
    let ppf = Format.std_formatter in
    Format.pp_set_margin ppf 100;
    Format.fprintf ppf "== %s@.%a@." s.file Types.pp_manifest s.manifest) sources
