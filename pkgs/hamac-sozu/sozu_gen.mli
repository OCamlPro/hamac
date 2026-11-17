(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(** Provider Sozu de Hamac : génération de la configuration de routage de
    [Sozu](https://sozu.io) (TOML) depuis les expositions des services d'un
    ensemble de manifestes.

    Pour chaque service déclaré avec un bloc [exposure], Hamac émet :

    - un [cluster] par service, dont le backend est le service lui-même
      ([hostname:port], la résolution de nom interne fait le reste) ;
    - un [frontend] par exposition : adresse d'écoute, nom d'hôte public et
      préfixe de chemin ;
    - un [listener] par (port, protocole) d'écoute, dédupliqué entre les
      services : [tcp] quand l'exposition est en TCP ou en TLS passthrough,
      [http] sinon. Le mode TLS ([acme], [internal], [passthrough]) est
      rappelé en commentaire de chaque frontend : la terminaison TLS se
      configure au déploiement, avec les certificats du cluster Sozu.

    Les routes protégées d'un service (étiquettes [security], voir le
    provider [hamac-biscuit]) sont rappelées en commentaire du cluster :
    c'est la validation Biscuit en bordure, appliquée par le connecteur
    Sozu avant que la requête n'atteigne le backend. *)

open Hamac_manifest.Types

type options = {
  listen_address: string;    (** défaut ["0.0.0.0"] *)
  command_socket: string;    (** défaut ["/run/sozu/command.sock"] *)
  worker_count: int;         (** défaut [1] *)
}

val default_options : options

(** Les services qui déclarent au moins une exposition, avec leurs
    expositions, dans l'ordre des services. *)
val exposed : service_manifest list -> (service_manifest * exposure list) list

(** La configuration TOML de Sozu pour les services donnés (les services sans
    exposition ne produisent aucun cluster). *)
val config : ?options:options -> service_manifest list -> string
