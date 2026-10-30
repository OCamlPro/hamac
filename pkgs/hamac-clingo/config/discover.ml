(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(* Options de compilation et d'édition de liens de libclingo, écrites dans
   c_flags.sexp et c_library_flags.sexp pour la stanza de la bibliothèque.

   Par ordre de priorité :
   1. CLINGO_CFLAGS / CLINGO_LIBS : les options, telles quelles (séparées
      par des blancs) ;
   2. CLINGO_PREFIX : un préfixe d'installation (<prefix>/include,
      <prefix>/lib), par exemple ~/.local/clingo pour un clingo construit
      depuis ses sources ; la bibliothèque y est trouvée à l'exécution par un
      rpath ;
   3. pkg-config, si un clingo.pc existe (clingo n'en installe pas
      aujourd'hui, mais une distribution peut le faire) ;
   4. le système : clingo.h et libclingo dans les chemins par défaut du
      compilateur (paquet clingo-devel de Fedora, clingo construit et
      installé dans /usr/local), puis les préfixes /usr/local et
      /opt/homebrew, que le compilateur ne cherche pas toujours (macOS).

   Debian et Ubuntu n'ont pas de paquet de développement de clingo : leur
   paquet gringo n'installe que les exécutables.

   La configuration retenue est vérifiée en compilant et liant un programme
   qui appelle clingo_version : une libclingo absente est signalée ici, avec
   la marche à suivre, plutôt que par une erreur obscure de l'éditeur de
   liens. *)

module C = Configurator.V1

let words s = String.split_on_char ' ' s |> List.filter (( <> ) "")
let env v = match Sys.getenv_opt v with Some s when String.trim s <> "" -> Some s | _ -> None

let probe = {|
#include <clingo.h>
int main(void) {
  int major, minor, revision;
  clingo_version(&major, &minor, &revision);
  return major == 5 ? 0 : 1;
}
|}

let of_prefix p =
  let lib = Filename.concat p "lib" in
  ("prefix " ^ p, [ "-I" ^ Filename.concat p "include" ],
   [ "-L" ^ lib; "-Wl,-rpath," ^ lib; "-lclingo" ])

let () =
  C.main ~name:"clingo" (fun c ->
      let works (_, cflags, libs) = C.c_test c probe ~c_flags:cflags ~link_flags:libs in
      let candidates =
        (* Une configuration donnée explicitement est la seule essayée. *)
        match env "CLINGO_CFLAGS", env "CLINGO_LIBS" with
        | Some cf, Some l -> [ ("CLINGO_CFLAGS/CLINGO_LIBS", words cf, words l) ]
        | Some _, None | None, Some _ ->
          C.die "CLINGO_CFLAGS and CLINGO_LIBS must be given together"
        | None, None ->
          match env "CLINGO_PREFIX" with
          | Some p -> [ of_prefix p ]
          | None ->
            let from_pc =
              match C.Pkg_config.get c with
              | None -> []
              | Some pc ->
                match C.Pkg_config.query pc ~package:"clingo" with
                | Some { cflags; libs } -> [ ("pkg-config clingo", cflags, libs) ]
                | None -> []
            in
            from_pc
            @ [ ("system", [], [ "-lclingo" ]); of_prefix "/usr/local"; of_prefix "/opt/homebrew" ]
      in
      match List.find_opt works candidates with
      | Some (_, cflags, libs) ->
        C.Flags.write_sexp "c_flags.sexp" cflags;
        C.Flags.write_sexp "c_library_flags.sexp" libs
      | None ->
        C.die
          "libclingo (clingo 5.x, C API) not found (tried: %s).\n\
           Install it (Fedora: clingo-devel; Homebrew: clingo), or build clingo from its \
           official sources (https://github.com/potassco/clingo, CMake) and set CLINGO_PREFIX \
           to its installation prefix (or CLINGO_CFLAGS and CLINGO_LIBS)."
          (String.concat ", " (List.map (fun (s, _, _) -> s) candidates)))
