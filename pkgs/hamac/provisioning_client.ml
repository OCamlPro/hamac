(** Client HTTP qui pousse un [rendered_profile] vers le discovery server.

    Endpoint cible : POST {discovery_url}/provisioning/<mac>
    Cf. doc/PROVISIONING_SPEC.md section 7.2. *)

open Lwt.Infix

type push_error =
  | Network_error of string
  | Server_error of int * string

let pp_push_error fmt = function
  | Network_error msg ->
    Format.fprintf fmt "erreur réseau : %s" msg
  | Server_error (code, body) ->
    Format.fprintf fmt "discovery server a répondu %d : %s" code body

(** Sérialise un [rendered_profile] au format attendu par
    POST /provisioning/<mac>. *)
let render_to_json (r : Provisioning_gen.rendered_profile) : Yojson.Safe.t =
  `Assoc [
    "profile_name", `String r.profile_name;
    "cloud_init", `String r.cloud_init;
    "ipxe_script", `String r.ipxe_script;
    "os_image_url", `String r.os_image_url;
    "os_image_sha256", `String r.os_image_sha256;
    "os_format", `String r.os_format;
  ]

(** Pousse un profil rendu pour une MAC donnée.
    [discovery_url] doit être un URL sans slash final, ex. "http://localhost:8877". *)
let push_lwt
    ~(discovery_url : string)
    ~(mac : string)
    (r : Provisioning_gen.rendered_profile)
  : (unit, push_error) Stdlib.result Lwt.t =
  let uri = Uri.of_string
    (Printf.sprintf "%s/provisioning/%s" discovery_url (Uri.pct_encode mac))
  in
  let body_str = Yojson.Safe.to_string (render_to_json r) in
  let body = Cohttp_lwt.Body.of_string body_str in
  let headers = Cohttp.Header.of_list [
    ("Content-Type", "application/json");
  ] in
  Lwt.catch
    (fun () ->
       Cohttp_lwt_unix.Client.post ~headers ~body uri >>= fun (resp, resp_body) ->
       let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
       Cohttp_lwt.Body.to_string resp_body >|= fun body_str ->
       if code >= 200 && code < 300 then Ok ()
       else Error (Server_error (code, body_str)))
    (fun e -> Lwt.return (Error (Network_error (Printexc.to_string e))))

(** Variant synchrone pour usage CLI. *)
let push ~discovery_url ~mac r =
  Lwt_main.run (push_lwt ~discovery_url ~mac r)

(** DELETE /provisioning/<mac>, pour clear. *)
let delete_lwt ~(discovery_url : string) ~(mac : string)
  : (unit, push_error) Stdlib.result Lwt.t =
  let uri = Uri.of_string
    (Printf.sprintf "%s/provisioning/%s" discovery_url (Uri.pct_encode mac))
  in
  Lwt.catch
    (fun () ->
       Cohttp_lwt_unix.Client.delete uri >>= fun (resp, resp_body) ->
       let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
       Cohttp_lwt.Body.to_string resp_body >|= fun body_str ->
       if code >= 200 && code < 300 then Ok ()
       else if code = 404 then Ok ()    (* déjà absent : idempotent *)
       else Error (Server_error (code, body_str)))
    (fun e -> Lwt.return (Error (Network_error (Printexc.to_string e))))

let delete ~discovery_url ~mac =
  Lwt_main.run (delete_lwt ~discovery_url ~mac)
