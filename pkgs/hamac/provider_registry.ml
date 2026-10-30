(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Provider registry for hamac.

    Indexes the providers of a set of manifests by name and capability for
    resolution. The providers are files of the set, like the services that
    consume them: the vocabulary resolves a consumption against them, and
    LOAF refuses a set whose templates read a provider that is not in it
    (L014). There is thus no search path of providers. *)

open Hamac_manifest.Types

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

let all_providers (registry : t) : service_manifest list =
  Hashtbl.fold (fun _name svc acc -> svc :: acc) registry.by_name []
