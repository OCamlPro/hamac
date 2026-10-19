(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Diagnostics of the validator.

    Every finding has a code from the catalogue of the manifest
    specification (doc/typst/manifest-spec.typ, section « Validation »), the
    YAML path it is about, and a message. Errors ([E…]) make a command fail;
    warnings ([W…]) only with [--strict]. *)

type severity = Error | Warning [@@deriving show]

type t = {
  code: string;            (** "E003", "W002"… *)
  severity: severity;
  path: string list;       (** YAML path, e.g. ["security"; "route_labels"; "1"] *)
  message: string;
} [@@deriving show]

let severity_of_code code =
  if String.length code > 0 && code.[0] = 'W' then Warning else Error

let make code path message =
  { code; severity = severity_of_code code; path; message }

let is_error d = d.severity = Error

let path_to_string = function
  | [] -> "(root)"
  | p -> String.concat "." p

(** ["security.zone: [E042] zone 'dmz' is not defined …"] *)
let to_string d =
  Printf.sprintf "%s: [%s] %s" (path_to_string d.path) d.code d.message

let pp fmt d = Format.pp_print_string fmt (to_string d)

(** Errors first, then by path, keeping the order of discovery otherwise. *)
let sort ds =
  List.stable_sort (fun a b ->
    match a.severity, b.severity with
    | Error, Warning -> -1
    | Warning, Error -> 1
    | _ -> 0) ds
