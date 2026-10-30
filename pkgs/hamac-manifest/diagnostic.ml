(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Diagnostics of the validator.

    Every finding has a code from the catalogue of the manifest
    specification (doc/typst/manifest-spec.typ, section « Validation »), or,
    for a refusal of the language itself, a code of the LOAF specification
    ([L001]…); the location of the element at fault (file, line, column),
    when known; the path of the value in {!Types} it is about, possibly
    empty; and a message. Errors ([E…], [L…]) make a command fail; warnings
    ([W…]) only with [--strict]. *)

type severity = Error | Warning [@@deriving show]

(** Location in a source file, line and column from 1. *)
type loc = {
  file: string;
  line: int;
  column: int;
} [@@deriving show]

type t = {
  code: string;            (** "E003", "W002", "L002"… *)
  severity: severity;
  path: string list;       (** path in {!Types}, e.g. ["security"; "route_labels"; "1"] *)
  loc: loc option;         (** location in a LOAF file *)
  message: string;
} [@@deriving show]

let severity_of_code code =
  if String.length code > 0 && code.[0] = 'W' then Warning else Error

let make ?loc code path message =
  { code; severity = severity_of_code code; path; loc; message }

let is_error d = d.severity = Error

let path_to_string = function
  | [] -> "(root)"
  | p -> String.concat "." p

(** ["security.zone: [E042] zone 'dmz' is not defined …"] *)
let to_string d =
  Printf.sprintf "%s: [%s] %s" (path_to_string d.path) d.code d.message

(** The finding attributed to [file]: ["file: security.zone: [E042] …"], or,
    when it has a location, ["hr-api.loaf:12:3: [E042] …"] (then followed
    by its path, if any: ["… [E011] artifact.sha256: expected …"]). *)
let to_string_in file d =
  match d.loc with
  | None -> Printf.sprintf "%s: %s" file (to_string d)
  | Some l ->
    let where = match d.path with [] -> "" | p -> path_to_string p ^ ": " in
    Printf.sprintf "%s:%d:%d: [%s] %s%s" l.file l.line l.column d.code where d.message

let pp fmt d = Format.pp_print_string fmt (to_string d)

(** Errors first, then by path, keeping the order of discovery otherwise. *)
let sort ds =
  List.stable_sort (fun a b ->
    match a.severity, b.severity with
    | Error, Warning -> -1
    | Warning, Error -> 1
    | _ -> 0) ds
