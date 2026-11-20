(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Voir {!Sozu_gen}. *)

open Hamac_manifest.Types

type options = {
  listen_address: string;
  command_socket: string;
  worker_count: int;
}

let default_options = {
  listen_address = "0.0.0.0";
  command_socket = "/run/sozu/command.sock";
  worker_count = 1;
}

let exposed services =
  List.filter_map (fun s ->
    match s.exposure with [] -> None | es -> Some (s, es)) services

(** L'identifiant de cluster d'un service : son nom d'hôte (RFC 1123). *)
let cluster_id (s : service_manifest) = hostname s.name

(** Les listeners, dédupliqués par port d'écoute, triés par port. Le
    protocole est [tcp] quand toutes les expositions du port sont en TCP ou
    en TLS passthrough, [http] sinon : la terminaison TLS (acme, internal) se
    configure au déploiement, avec les certificats du cluster Sozu. *)
let listeners_of exps =
  let by_port = Hashtbl.create 8 in
  List.iter (fun (_, es) ->
    List.iter (fun (e : exposure) ->
      let tcp = e.exp_protocol = "tcp" || e.tls = "passthrough" in
      match Hashtbl.find_opt by_port e.exp_port with
      | Some prev -> Hashtbl.replace by_port e.exp_port (prev && tcp)
      | None -> Hashtbl.replace by_port e.exp_port tcp)
      es)
    exps;
  Hashtbl.fold (fun port tcp acc -> (port, if tcp then "tcp" else "http") :: acc) by_port []
  |> List.sort (fun (a, _) (b, _) -> compare a b)

let config ?(options = default_options) services =
  let b = Buffer.create 1024 in
  let p fmt = Printf.ksprintf (fun s -> Buffer.add_string b s; Buffer.add_char b '\n') fmt in
  let exps = exposed services in
  p "# Configuration Sozu générée par hamac (provider hamac-sozu)"
  ; (match exps with
     | [] -> p "# aucun service exposé"
     | _ -> p "# services exposés : %s"
              (String.concat ", "
                 (List.map (fun ((s : service_manifest), _) -> hostname s.name) exps)))
  ; p ""
  ; p "command_socket = %S" options.command_socket
  ; p "log_level = \"info\""
  ; p "worker_count = %d" options.worker_count
  ; List.iter (fun (port, proto) ->
      p ""
      ; p "[[listeners]]"
      ; p "address = %S" (Printf.sprintf "%s:%d" options.listen_address port)
      ; p "protocol = %S" proto)
      (listeners_of exps)
  ; List.iter (fun ((s : service_manifest), es) ->
      let id = cluster_id s in
      let cluster_proto =
        if List.exists (fun (e : exposure) -> e.exp_protocol = "tcp") es then "tcp" else "http" in
      p ""
      ; (match s.security with
         | Some sec ->
           let protected = List.filter (fun r -> not r.public) sec.route_labels in
           if protected <> [] then begin
             p "# routes protégées (validation Biscuit en bordure — hamac biscuit authorizers) :"
             ; List.iter (fun (r : route_label) ->
                 p "#   %s%s" r.route
                   (match r.methods with [] -> "" | ms -> " [" ^ String.concat "," ms ^ "]"))
                 protected
           end
         | None -> ())
      ; p "[clusters.%S]" id
      ; p "protocol = %S" cluster_proto
      ; p "load_balancing = \"ROUND_ROBIN\""
      ; List.iter (fun (e : exposure) ->
          p ""
          ; p "[[clusters.%S.frontends]]" id
          ; p "address = %S" (Printf.sprintf "%s:%d" options.listen_address e.exp_port)
          ; p "hostname = %S" e.hostname
          ; p "path = %S" (if e.path_prefix = "" then "/" else e.path_prefix)
          ; p "# tls: %s (terminaison au déploiement, avec les certificats)" e.tls)
          es
      ; (* un backend par port exposé du service *)
        let ports =
          List.sort_uniq compare (List.map (fun (e : exposure) -> e.exp_port) es) in
        List.iter (fun port ->
          p ""
          ; p "[[clusters.%S.backends]]" id
          ; p "address = %S" (Printf.sprintf "%s:%d" (hostname s.name) port)
          ; p "backend_id = %S" (hostname s.name))
          ports)
    exps
  ; Buffer.contents b
