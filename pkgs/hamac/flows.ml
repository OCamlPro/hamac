(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Security zones, declared flows and the filtering they allow.

    Zones form a Bell-LaPadula lattice ordered by sensitivity
    (public < default < internal < secure). At the network level, opening a
    connection to a service means reading from it, so:

    - a zone may never open a connection to a more sensitive zone
      (no read up) — this is an invariant, no declaration can lift it;
    - reading down (a more sensitive zone querying a less sensitive one) is
      permitted by the lattice, but only opened for flows a service declares
      with a [consumes: - service: ...] entry (least privilege);
    - everything else between two zones is denied.

    Filtering is stateful: replies to an allowed connection pass.

    Writing down (a sensitive service sending data to a less sensitive
    zone, including inside the request of an allowed read-down connection)
    is not a network matter: it is controlled at the application level
    (information-flow typing in SIESTE, Biscuit authorization) or by a
    filtering data diode. *)

open Hamac_provisioning.Manifest_types

(** Zones in increasing order of sensitivity. *)
let zone_order = ["public"; "default"; "internal"; "secure"]

(** Sensitivity level of a zone; unknown zones are treated as "default". *)
let zone_level (zone : string) : int =
  let rec aux i = function
    | [] -> 1
    | z :: _ when z = zone -> i
    | _ :: rest -> aux (i + 1) rest
  in
  aux 0 zone_order

(** Zone of a service (default: "default"). *)
let service_zone (svc : service_manifest) : string =
  match svc.security with
  | Some s -> s.zone
  | None -> "default"

(** A connection a service declares it opens to another service. *)
type flow = {
  consumer: string;
  consumer_zone: string;
  consume_name: string;
  target: string;
  target_zone: string;
}

(** Flows declared by the services of a stack, checked against the lattice.
    Returns the valid flows and one error per invalid declaration. *)
let declared (services : service_manifest list) : flow list * string list =
  let find name = List.find_opt (fun (s : service_manifest) -> s.name = name) services in
  let flows = ref [] and errors = ref [] in
  List.iter (fun (svc : service_manifest) ->
    List.iter (fun (c : consumption) ->
      match c.service with
      | None -> ()
      | Some target_name ->
        match find target_name with
        | None ->
          errors := Printf.sprintf
              "%s: consumes '%s': unknown service '%s' (not part of this stack)"
              svc.name c.name target_name :: !errors
        | Some target ->
          let consumer_zone = service_zone svc and target_zone = service_zone target in
          if zone_level consumer_zone < zone_level target_zone then
            errors := Printf.sprintf
                "%s (zone %s) cannot consume %s (zone %s): opening a connection \
                 to a more sensitive zone is a read up, forbidden by the \
                 Bell-LaPadula model. If %s must expose data to zone %s, have \
                 it push the declassified data to a service of that zone \
                 through a declared guard."
                svc.name consumer_zone target.name target_zone
                target.name consumer_zone :: !errors
          else
            flows := { consumer = svc.name; consumer_zone; consume_name = c.name;
                       target = target.name; target_zone } :: !flows
    ) svc.consumes
  ) services;
  (List.rev !flows, List.rev !errors)

(** Filtering rules between the given zones: one [Allow] per declared
    cross-zone flow, one [Deny] for every ordered pair of zones left
    without any. Flows inside a zone need no rule. *)
let firewall_rules (zones : string list) (flows : flow list) : firewall_rule list =
  List.concat_map (fun src ->
    List.concat_map (fun dst ->
      if src = dst then []
      else
        let opened = List.filter_map (fun f ->
          if f.consumer_zone = src && f.target_zone = dst
          then Some (f.consumer, f.target) else None) flows
          |> List.sort_uniq compare in
        if opened <> [] then
          List.map (fun pair ->
            { action = Allow; src_zone = src; dst_zone = dst;
              flow = Some pair; reason = None }) opened
        else
          let reason =
            if zone_level src < zone_level dst then "no read up"
            else "no declared flow"
          in
          [{ action = Deny; src_zone = src; dst_zone = dst; flow = None;
             reason = Some reason }]
    ) zones
  ) zones
