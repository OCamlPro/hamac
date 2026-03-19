(** Compose generator for hamac.

    Generates a docker-compose.yml from a resolved stack.
    This is intentionally minimal — a stepping stone to validate
    wiring before implementing infrastructure simulation. *)

open Manifest_types
open Resolver

(* ============================================================ *)
(* YAML emitter (minimal, no dependency)                         *)
(* ============================================================ *)

let indent n buf =
  for _ = 1 to n do Buffer.add_string buf "  " done

let emit_line buf depth fmt =
  let k s = indent depth buf; Buffer.add_string buf s; Buffer.add_char buf '\n' in
  Printf.ksprintf k fmt

(* ============================================================ *)
(* Compose generation                                            *)
(* ============================================================ *)

(** Build the substitution table for a resolved provider *)
let provider_vars (rp : resolved_provider) : (string * string) list =
  (* resolved_env contains the final values, but keyed by env var name
     (e.g. POSTGRES_USER). We need input.* keys for readiness templates. *)
  (* Reverse-engineer input values from resolved_env via provider's environment templates *)
  let input_vars = List.filter_map (fun (k, v) ->
    (* provider.environment maps ENV_VAR -> "{input.key}" *)
    let tmpl = List.assoc_opt k rp.provider.environment in
    match tmpl with
    | Some t when String.length t > 8
                  && String.sub t 0 7 = "{input."
                  && t.[String.length t - 1] = '}' ->
      let input_key = String.sub t 7 (String.length t - 8) in
      Some ("input." ^ input_key, v)
    | _ -> None
  ) rp.resolved_env in
  ("service_name", rp.instance_name) :: input_vars

(** Generate docker-compose service block for a provider instance *)
let emit_provider buf (rp : resolved_provider) =
  let image = match rp.provider.artifact with
    | Some a when a.format = "oci-image" -> a.path
    | _ -> rp.provider.name  (* fallback to provider name *)
  in
  emit_line buf 1 "%s:" rp.instance_name;
  emit_line buf 2 "image: %s" image;
  emit_line buf 2 "container_name: %s" rp.instance_name;
  (* Environment *)
  if rp.resolved_env <> [] then begin
    emit_line buf 2 "environment:";
    List.iter (fun (k, v) ->
      emit_line buf 3 "%s: \"%s\"" k v
    ) rp.resolved_env
  end;
  (* Ports — don't expose provider ports externally in flat compose,
     services reach them via container_name on the internal network *)
  (* Healthcheck from readiness *)
  (match rp.provider.readiness with
   | Some r when r.command <> [] ->
     emit_line buf 2 "healthcheck:";
     let vars = provider_vars rp in
     let resolved_cmd = List.map (Resolver.substitute vars) r.command in
     let cmd = String.concat "\", \"" resolved_cmd in
     emit_line buf 3 "test: [\"CMD\", \"%s\"]" cmd;
     emit_line buf 3 "interval: %ds" r.readiness_interval;
     emit_line buf 3 "timeout: %ds" r.readiness_timeout;
     emit_line buf 3 "retries: 5"
   | _ -> ());
  (* Restart policy *)
  emit_line buf 2 "restart: unless-stopped";
  (* Networks *)
  emit_line buf 2 "networks:";
  emit_line buf 3 "- hamac"

(** Collect injected env vars for a given consumer from all wires *)
let consumer_env (resolution : resolution) (consumer_name : string) : (string * string) list =
  List.fold_left (fun acc (w : resolved_wire) ->
    if w.consumer_name = consumer_name then
      acc @ w.injected_env
    else acc
  ) [] resolution.wires

(** Generate docker-compose service block for a consumer service *)
let emit_service buf (resolution : resolution) (svc : service_manifest) =
  emit_line buf 1 "%s:" svc.name;
  (* Image or build context *)
  (match svc.artifact with
   | Some a when a.format = "oci-image" ->
     emit_line buf 2 "image: %s" a.path
   | Some a ->
     (* Native binary — use a generic image + volume mount *)
     emit_line buf 2 "image: debian:bookworm-slim";
     emit_line buf 2 "volumes:";
     emit_line buf 3 "- %s:/app/service:ro" a.path;
     emit_line buf 2 "command: [\"/app/service\"]"
   | None ->
     emit_line buf 2 "image: debian:bookworm-slim");
  emit_line buf 2 "container_name: %s" svc.name;
  (* Environment: service's own env + injected from wiring *)
  let injected = consumer_env resolution svc.name in
  let all_env = svc.environment @ injected in
  if all_env <> [] then begin
    emit_line buf 2 "environment:";
    List.iter (fun (k, v) ->
      emit_line buf 3 "%s: \"%s\"" k v
    ) all_env
  end;
  (* Ports *)
  if svc.ports <> [] then begin
    emit_line buf 2 "ports:";
    List.iter (fun (p : port) ->
      emit_line buf 3 "- \"%d:%d\"" p.host p.container
    ) svc.ports
  end;
  (* Resources *)
  (match svc.resources with
   | Some r ->
     emit_line buf 2 "deploy:";
     emit_line buf 3 "resources:";
     emit_line buf 4 "limits:";
     (match r.memory_limit with
      | Some ml -> emit_line buf 5 "memory: %s" ml
      | None -> ());
     (match r.cpu_limit with
      | Some cl -> emit_line buf 5 "cpus: \"%s\"" cl
      | None -> ())
   | None -> ());
  (* Depends on: all providers this service consumes *)
  let deps = List.filter_map (fun (w : resolved_wire) ->
    if w.consumer_name = svc.name then Some w
    else None
  ) resolution.wires in
  if deps <> [] then begin
    emit_line buf 2 "depends_on:";
    List.iter (fun (w : resolved_wire) ->
      let instance_name = Printf.sprintf "%s-%s-%s"
        w.provider_name w.consumer_name w.consume_name in
      (* Use condition if provider has healthcheck *)
      let has_healthcheck = List.exists (fun (rp : resolved_provider) ->
        rp.instance_name = instance_name && rp.provider.readiness <> None
      ) resolution.providers in
      if has_healthcheck then begin
        emit_line buf 3 "%s:" instance_name;
        emit_line buf 4 "condition: service_healthy"
      end else
        emit_line buf 3 "- %s" instance_name
    ) deps
  end;
  (* Restart and network *)
  emit_line buf 2 "restart: unless-stopped";
  emit_line buf 2 "networks:";
  emit_line buf 3 "- hamac"

(** Generate the complete docker-compose.yml content *)
let generate
    ~(services : service_manifest list)
    (resolution : resolution)
  : string =
  let buf = Buffer.create 1024 in
  (* Header *)
  Buffer.add_string buf "# Generated by hamac — do not edit\n";
  emit_line buf 0 "services:";
  (* Provider instances first *)
  List.iter (fun rp ->
    emit_provider buf rp;
    Buffer.add_char buf '\n'
  ) resolution.providers;
  (* Consumer services *)
  List.iter (fun svc ->
    emit_service buf resolution svc;
    Buffer.add_char buf '\n'
  ) services;
  (* Network *)
  emit_line buf 0 "networks:";
  emit_line buf 1 "hamac:";
  emit_line buf 2 "driver: bridge";
  Buffer.contents buf
