(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Security zones, declared flows and the filtering they allow.

    Zones carry labels of a Bell-LaPadula lattice ({!Lattice}):
    the stack's patterns define it, the built-in one orders
    public < default < internal < secure. At the network level, opening a
    connection to a service means reading from it, so:

    - a zone may never open a connection to a more sensitive zone
      (no read up) — this is an invariant, no declaration can lift it;
    - reading down (a more sensitive zone querying a less sensitive one) is
      permitted by the lattice, but only opened for flows a service declares
      with a [consumes: - service: ...] entry (least privilege);
    - everything else between two zones is denied.

    Filtering is stateful: replies to an allowed connection pass. Across a
    zone whose boundary is a diode, nothing can answer a request: a flow
    that crosses it must be declared [mode: push].

    Writing down (a sensitive service sending data to a less sensitive
    zone, including inside the request of an allowed read-down connection)
    is not a network matter: it is controlled at the application level
    (information-flow typing in the source language, Biscuit authorization) or by a
    filtering data diode. *)

open Types


(** Zones of the built-in lattice, in increasing order of sensitivity. *)
let zone_order = Lattice.builtin_levels

(** The zone of a lattice, or a zone of label "default" for an unknown name
    — unknown zones are reported beforehand, as E042, by validation. *)
let zone_of (lattice : Lattice.t) (name : string) : Lattice.zone =
  match Lattice.find lattice name with
  | Some z -> z
  | None ->
    { Lattice.name; level = "default"; rank = 1; categories = []; boundary = "firewall" }

(** Sensitivity rank of a zone of the built-in lattice. *)
let zone_level (zone : string) : int = (zone_of Lattice.default zone).rank

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

(** An invalid flow declaration: service, index of its [consumes] entry, and
    the diagnostic (E020 unknown service, E040 read up, E041 request across a
    diode). *)
type error = {
  service: string;
  consume_index: int;
  diag: Diagnostic.t;
}

let error_to_string e =
  Printf.sprintf "[%s] %s" e.diag.Diagnostic.code e.diag.message

(** Flows declared by the services of a stack, checked against the lattice.
    Returns the valid flows and one error per invalid declaration. *)
let declared ?(lattice = Lattice.default) (services : service_manifest list)
  : flow list * error list =
  let find name = List.find_opt (fun (s : service_manifest) -> s.name = name) services in
  let flows = ref [] and errors = ref [] in
  List.iter (fun (svc : service_manifest) ->
    List.iteri (fun i (c : consumption) ->
      let fail code fmt =
        Printf.ksprintf (fun message ->
          errors := { service = svc.name; consume_index = i;
                      diag = Diagnostic.make code
                          ["consumes"; string_of_int i] message } :: !errors) fmt in
      match c.service with
      | None -> ()
      | Some target_name ->
        match find target_name with
        | None ->
          fail "E020" "%s: consumes '%s': unknown service '%s' (not part of this stack)"
            svc.name c.name target_name
        | Some target ->
          let consumer_zone = service_zone svc and target_zone = service_zone target in
          let cz = zone_of lattice consumer_zone and tz = zone_of lattice target_zone in
          if not (Lattice.leq tz cz) then
            fail "E040"
              "%s (zone %s) cannot consume %s (zone %s): opening a connection \
               to a more sensitive zone is a read up, forbidden by the \
               Bell-LaPadula model. If %s must expose data to zone %s, have \
               it push the declassified data to a service of that zone \
               through a declared guard."
              svc.name consumer_zone target.name target_zone
              target.name consumer_zone
          else if cz.name <> tz.name
               && (cz.boundary = "diode" || tz.boundary = "diode")
               && c.mode <> "push" then
            fail "E041"
              "%s (zone %s) consumes %s (zone %s) across a diode: nothing \
               can answer a request through it. Declare the flow 'mode: push', \
               %s sending what %s receives."
              svc.name consumer_zone target.name target_zone target.name svc.name
          else
            flows := { consumer = svc.name; consumer_zone; consume_name = c.name;
                       target = target.name; target_zone } :: !flows
    ) svc.consumes
  ) services;
  (List.rev !flows, List.rev !errors)

(** Filtering rules between the given zones: one [Allow] per declared
    cross-zone flow, one [Deny] for every ordered pair of zones left
    without any. Flows inside a zone need no rule. *)
let firewall_rules ?(lattice = Lattice.default) (zones : string list) (flows : flow list)
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
          let reason =
            if not (Lattice.leq (zone_of lattice dst) (zone_of lattice src))
            then "no read up"
            else "no declared flow"
          in
          [{ action = Deny; src_zone = src; dst_zone = dst; flow = None;
             reason = Some reason }]
    ) zones
  ) zones
