(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Declared flows and the filtering they allow.

    Opening a connection to a service means reading from it. The security
    models that the patterns load define which zone may read which
    ([zone_leq] of the vocabulary); the vocabulary refuses a flow that its
    zones do not allow (E040), or that crosses a diode without being
    [mode push] (E041). This module only derives the filtering of a
    topology from the flows, once they are accepted:

    - a flow a service declares with a [consumes n { service s. }] entry
      opens connections from its zone to that of [s];
    - everything else between two zones is denied, the reason telling a
      read up (forbidden by the model) from a missing declaration.

    Filtering is stateful: replies to an allowed connection pass. Writing
    down (a sensitive service sending data to a less sensitive zone,
    including inside the reply to an allowed connection) is not a network
    matter: it is controlled at the application level, by the access
    control of the routes, or by a filtering data diode. *)

open Types

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

(** Flows declared by the services: one per consumption of a service among
    [services]. A consumption of a service outside them (a provider) opens
    no flow of the topology. *)
let declared (services : service_manifest list) : flow list =
  let find name = List.find_opt (fun (s : service_manifest) -> s.name = name) services in
  List.concat_map (fun (svc : service_manifest) ->
    List.filter_map (fun (c : consumption) ->
      Option.bind c.service (fun target_name ->
        Option.map (fun (target : service_manifest) ->
          { consumer = svc.name; consumer_zone = service_zone svc; consume_name = c.name;
            target = target.name; target_zone = service_zone target })
          (find target_name)))
      svc.consumes)
    services

(** Filtering rules between the given zones: one [Allow] per declared
    cross-zone flow, one [Deny] for every ordered pair of zones left
    without any. [leq a b]: zone [b] may read zone [a] (the [zone_leq] of
    the security models); a pair it does not allow is denied as a read up.
    Flows inside a zone need no rule. *)
let firewall_rules ~(leq : string -> string -> bool) (zones : string list) (flows : flow list)
  : firewall_rule list =
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
          let reason = if not (leq dst src) then "no read up" else "no declared flow" in
          [{ action = Deny; src_zone = src; dst_zone = dst; flow = None;
             reason = Some reason }]
    ) zones
  ) zones
