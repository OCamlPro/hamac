(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2025-2026 OCamlPro <contact@ocamlpro.com> *)

(** Resolver for hamac.

    Resolves service consumes to concrete providers, generates credentials,
    and substitutes injection templates. *)

open Hamac_provisioning.Manifest_types

(* ============================================================ *)
(* Credential generation                                         *)
(* ============================================================ *)

let alpha_chars = "abcdefghijklmnopqrstuvwxyz"
let alnum_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

(* Source d'aléa des credentials.

   Par défaut, les credentials sont des mots de passe de production : ils sont
   tirés de la source cryptographique du système (/dev/urandom), pas d'un PRNG
   généraliste.

   [set_seed] bascule sur un générateur déterministe pour les tests et les
   démonstrations. Il est implémenté ici plutôt que délégué à [Random] parce que
   l'implémentation de [Random] a changé en OCaml 5.0 : une même graine n'y
   produit pas la même suite d'une version du compilateur à l'autre, ce qui
   suffirait à faire diverger une sortie de référence entre le poste de
   développement et la CI. SplitMix64 (Steele, Lea & Flood, 2014) tient en
   quelques lignes et fixe la suite une fois pour toutes. *)

type rng =
  | Urandom                (** défaut : source cryptographique du système *)
  | Seeded of int64 ref    (** [--seed] : SplitMix64, stable entre versions *)

let rng = ref Urandom

(** Fixe la graine du générateur de credentials : deux exécutions sur les mêmes
    manifestes produisent alors les mêmes valeurs, quel que soit le compilateur.
    Destiné aux tests et aux démonstrations — les credentials en deviennent
    prévisibles. *)
let set_seed (seed : int) : unit = rng := Seeded (ref (Int64.of_int seed))

let splitmix_next (st : int64 ref) : int64 =
  let open Int64 in
  st := add !st 0x9E3779B97F4A7C15L;
  let z = !st in
  let z = mul (logxor z (shift_right_logical z 30)) 0xBF58476D1CE4E5B9L in
  let z = mul (logxor z (shift_right_logical z 27)) 0x94D049BB133111EBL in
  logxor z (shift_right_logical z 31)

(* Ouvert une fois, pas à chaque octet. Si la source manque (système sans
   /dev/urandom), on retombe sur [Random] auto-initialisé : moins bon, mais
   toujours imprévisible. *)
let urandom : in_channel option Lazy.t =
  lazy (try Some (open_in_bin "/dev/urandom") with Sys_error _ -> None)

let fallback_state = lazy (Random.State.make_self_init ())

(** Entier uniforme dans [0, n), pour n <= 256. Le tirage cryptographique
    rejette les valeurs qui biaiseraient le reste ; la voie SplitMix s'en
    dispense, le biais y étant borné par 2^-56. *)
let rng_int (n : int) : int =
  match !rng with
  | Seeded st -> Int64.to_int (Int64.unsigned_rem (splitmix_next st) (Int64.of_int n))
  | Urandom ->
    match Lazy.force urandom with
    | None -> Random.State.int (Lazy.force fallback_state) n
    | Some ic ->
      let limit = 256 - (256 mod n) in
      let rec draw () =
        let b = input_byte ic in
        if b < limit then b mod n else draw ()
      in
      draw ()

let generate_string (charset : string) (len : int) : string =
  String.init len (fun _ -> charset.[rng_int (String.length charset)])

(** Parse a generate directive like "{generate.alpha(12)}" or "{generate.alnum(32)}"
    and return the generated string. Returns None if not a generate directive. *)
let eval_generate (s : string) : string option =
  let s = String.trim s in
  if String.length s > 2 && s.[0] = '{' && s.[String.length s - 1] = '}' then begin
    let inner = String.sub s 1 (String.length s - 2) in
    let inner = String.trim inner in
    if String.length inner > 15 && String.sub inner 0 9 = "generate." then begin
      let rest = String.sub inner 9 (String.length inner - 9) in
      (* Parse "alpha(N)" or "alnum(N)" *)
      let parse_call prefix charset =
        let plen = String.length prefix in
        if String.length rest > plen + 2
           && String.sub rest 0 plen = prefix
           && rest.[plen] = '('
        then begin
          let closing = String.index_opt rest ')' in
          match closing with
          | Some ci ->
            let num_str = String.sub rest (plen + 1) (ci - plen - 1) in
            (try Some (generate_string charset (int_of_string num_str))
             with _ -> None)
          | None -> None
        end else None
      in
      match parse_call "alpha" alpha_chars with
      | Some _ as r -> r
      | None ->
        match parse_call "alnum" alnum_chars with
        | Some _ as r -> r
        | None -> None
    end else None
  end else None

(* ============================================================ *)
(* Template substitution                                         *)
(* ============================================================ *)

(** Substitute {key} patterns in a template string using a lookup table *)
let substitute (vars : (string * string) list) (template : string) : string =
  let buf = Buffer.create (String.length template) in
  let len = String.length template in
  let i = ref 0 in
  while !i < len do
    if template.[!i] = '{' then begin
      (* Find closing brace *)
      match String.index_from_opt template (!i + 1) '}' with
      | Some j ->
        let key = String.sub template (!i + 1) (j - !i - 1) in
        (match List.assoc_opt key vars with
         | Some value -> Buffer.add_string buf value
         | None ->
           (* Keep unresolved variable as-is *)
           Buffer.add_char buf '{';
           Buffer.add_string buf key;
           Buffer.add_char buf '}');
        i := j + 1
      | None ->
        Buffer.add_char buf template.[!i];
        incr i
    end else begin
      Buffer.add_char buf template.[!i];
      incr i
    end
  done;
  Buffer.contents buf

(* ============================================================ *)
(* Resolution result                                             *)
(* ============================================================ *)

type resolved_wire = {
  consumer_name: string;         (** service that consumes *)
  consume_name: string;          (** name of the consumption *)
  provider_name: string;         (** resolved provider name *)
  generated_inputs: (string * string) list;  (** credentials generated *)
  injected_env: (string * string) list;      (** final env vars to inject *)
}

type resolved_provider = {
  provider: service_manifest;    (** the provider manifest *)
  instance_name: string;         (** instance name (e.g., "postgresql-hr_api-db") *)
  resolved_env: (string * string) list;  (** provider env with substituted values *)
}

type resolution = {
  wires: resolved_wire list;
  providers: resolved_provider list;
  errors: string list;
}

(* ============================================================ *)
(* Core resolution                                               *)
(* ============================================================ *)

(** Resolve inputs for a provider: evaluate generate directives
    and substitute {consumer.name} references *)
let resolve_inputs
    ~(consumer_name : string)
    (provider : service_manifest) : (string * string) list =
  List.map (fun (key, template) ->
    let value = match eval_generate template with
      | Some generated -> generated
      | None ->
        (* Substitute {consumer.name} *)
        substitute [("consumer.name", consumer_name)] template
    in
    (key, value)
  ) provider.inputs

(** Resolve a single consumption for a service *)
let resolve_consumption
    ~(registry : Provider_registry.t)
    ~(consumer : service_manifest)
    ~(provider_override : string option)
    (cons : consumption)
  : (resolved_wire * resolved_provider) option * string option =
  (* Find the provider *)
  let provider_opt = Provider_registry.resolve registry
    ~provider_name:provider_override
    ~capability:cons.capability
  in
  match provider_opt with
  | None ->
    let target = match provider_override with
      | Some n -> Printf.sprintf "provider '%s'" n
      | None -> match cons.capability with
        | Some c -> Printf.sprintf "capability '%s'" c
        | None -> "???"
    in
    (None, Some (Printf.sprintf "%s: consumes '%s': no provider found for %s"
      consumer.name cons.name target))
  | Some provider ->
    (* Generate inputs (credentials) *)
    let generated_inputs = resolve_inputs ~consumer_name:consumer.name provider in

    (* Build the variable table for substitution:
       input.* = generated inputs
       service_name = instance name *)
    let instance_name = Printf.sprintf "%s-%s-%s" provider.name consumer.name cons.name in
    let input_vars = List.map (fun (k, v) -> ("input." ^ k, v)) generated_inputs in
    let all_vars = ("service_name", instance_name) :: input_vars in

    (* Resolve provider's provides *)
    let resolved_provides = List.map (fun (k, tmpl) ->
      (k, substitute all_vars tmpl)
    ) provider.provides in

    (* Resolve consumer's inject templates using resolved provides *)
    let injected_env = List.map (fun (env_var, tmpl) ->
      (env_var, substitute resolved_provides tmpl)
    ) cons.inject in

    (* Resolve provider's own environment variables *)
    let resolved_provider_env = List.map (fun (k, tmpl) ->
      (k, substitute all_vars tmpl)
    ) provider.environment in

    let wire = {
      consumer_name = consumer.name;
      consume_name = cons.name;
      provider_name = provider.name;
      generated_inputs;
      injected_env;
    } in
    let rprovider = {
      provider;
      instance_name;
      resolved_env = resolved_provider_env;
    } in
    (Some (wire, rprovider), None)

(** Resolve all consumptions for a list of services with optional stack overrides *)
let resolve_all
    ~(registry : Provider_registry.t)
    ~(services : service_manifest list)
    ~(overrides : (string * (string * string) list) list)
    (** overrides: (service_name, [(consume_name, provider_name)]) *)
  : resolution =
  let wires = ref [] in
  let providers = ref [] in
  let errors = ref [] in
  let seen_providers = Hashtbl.create 8 in

  List.iter (fun (svc : service_manifest) ->
    let svc_overrides = match List.assoc_opt svc.name overrides with
      | Some l -> l
      | None -> []
    in
    List.iter (fun (cons : consumption) ->
      let provider_override = List.assoc_opt cons.name svc_overrides in
      match resolve_consumption ~registry ~consumer:svc ~provider_override cons with
      | (Some (wire, rprov), _) ->
        wires := wire :: !wires;
        (* Deduplicate providers by instance name *)
        if not (Hashtbl.mem seen_providers rprov.instance_name) then begin
          Hashtbl.replace seen_providers rprov.instance_name ();
          providers := rprov :: !providers
        end
      | (None, Some err) ->
        errors := err :: !errors
      | _ -> ()
    ) svc.consumes
  ) services;

  {
    wires = List.rev !wires;
    providers = List.rev !providers;
    errors = List.rev !errors;
  }
