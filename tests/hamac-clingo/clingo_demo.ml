(* SPDX-License-Identifier: AGPL-3.0-only *)
(* Copyright (C) 2026 OCamlPro <contact@ocamlpro.com> *)

(* Démonstrateur de la liaison hamac-clingo : chaque sous-commande exerce
   une partie de l'API et imprime ce qu'elle lit (cf. clingo.t). *)

module C = Hamac_clingo.Clingo

let pp_model ppf (m : C.model) =
  Fmt.pf ppf "%a cost=[%a]" Fmt.(list ~sep:(any " ") C.pp_symbol) m.symbols
    Fmt.(list ~sep:(any ",") int) m.cost

let pp_outcome ppf (o : C.outcome) =
  Fmt.pf ppf "satisfiable=%s exhausted=%b"
    (match o.satisfiable with Some b -> string_of_bool b | None -> "unknown")
    o.exhausted

(* Un sac à dos : chaque objet est pris ou non (choix), le poids total est
   borné (contrainte), la valeur maximisée et, à valeur égale, le nombre
   d'objets minimisé (deux priorités). *)
let knapsack = {|
item(a, 3, 4).  item(b, 4, 5).  item(c, 2, 3).  item(d, 5, 8).
capacity(9).
{ take(I) : item(I, _, _) }.
:- capacity(C), #sum { W, I : take(I), item(I, W, _) } > C.
#maximize { V@2, I : take(I), item(I, _, V) }.
#minimize { 1@1, I : take(I) }.
#show take/1.
|}

let optimal () =
  C.with_control (fun ctl ->
      C.add ctl knapsack;
      C.ground ctl;
      (match C.optimal ctl with
       | Some m -> Fmt.pr "optimal: %a@." pp_model m
       | None -> Fmt.pr "no model@.");
      (* Les modèles successifs d'une optimisation, de coût décroissant. *)
      let costs, outcome = C.fold ctl ~init:[] (fun acc (m : C.model) -> m.cost :: acc) in
      Fmt.pr "costs: %a, %a@."
        Fmt.(list ~sep:(any " > ") (brackets (list ~sep:(any ",") int))) (List.rev costs)
        pp_outcome outcome);
  (* Avec --opt-mode=optN, les modèles optimaux, dont l'optimalité est
     prouvée. *)
  C.with_control ~args:[ "--opt-mode=optN"; "--models=0" ] (fun ctl ->
      C.add ctl "1 { p(1..3) } 1. #minimize { 1, X : p(X), X > 1 }.";
      C.ground ctl;
      let optimal, _ = C.fold ctl ~init:[] (fun acc (m : C.model) ->
          if m.optimality_proven then m :: acc else acc) in
      List.iter (Fmt.pr "proven: %a@." pp_model) (List.rev optimal))

(* Tous les modèles d'un choix, avec --models=0. *)
let all () =
  C.with_control ~args:[ "--models=0" ] (fun ctl ->
      C.add ctl "1 { p(1..3) } 2.";
      C.ground ctl;
      let models, outcome = C.fold ctl ~init:[] (fun acc m -> m :: acc) in
      List.iter (fun (m : C.model) -> Fmt.pr "%a@." pp_model m)
        (List.sort (fun (a : C.model) b -> List.compare C.compare_symbol a.symbols b.symbols) models);
      Fmt.pr "%d models, %a@." (List.length models) pp_outcome outcome)

(* Les symboles de toutes les sortes, et une partie paramétrée. *)
let symbols () =
  C.with_control (fun ctl ->
      C.add ctl {|t(1, -7, "a\"b", c, f(x, (1, 2)), (), (u,), #inf, #sup, -g(2)).|};
      C.add ctl ~name:"step" ~params:[ "k" ] "s(k, k + 1).";
      C.ground ~parts:[ ("base", []); ("step", [ C.Int 41 ]); ("step", [ C.Fun ("z", []) ]) ] ctl;
      match C.optimal ~show:C.Atoms ctl with
      | Some m ->
        List.iter (fun s ->
            Fmt.pr "%a@." C.pp_symbol s;
            match s with
            | C.Fun ("t", args) ->
              List.iter (fun a ->
                  Fmt.pr "  %s@." (match a with
                    | C.Inf -> "Inf" | C.Sup -> "Sup" | C.Int n -> Fmt.str "Int %d" n
                    | C.Str s -> Fmt.str "Str %S" s
                    | C.Fun (f, xs) -> Fmt.str "Fun (%S, %d args)" f (List.length xs)
                    | C.Neg (f, xs) -> Fmt.str "Neg (%S, %d args)" f (List.length xs)))
                args
            | _ -> ()) m.symbols
      | None -> Fmt.pr "no model@.");
  (* k + 1 sur z est indéfini : clingo le signale dans son journal. *)
  C.with_control (fun ctl ->
      C.add ctl ~name:"step" ~params:[ "k" ] "s(k, k + 1). r :- q.";
      C.ground ~parts:[ ("step", [ C.Fun ("z", []) ]) ] ctl;
      List.iter (fun (w, m) ->
          Fmt.pr "%s: %s@."
            (match w with C.Operation_undefined -> "operation_undefined"
                        | C.Atom_undefined -> "atom_undefined" | _ -> "other")
            (List.hd (String.split_on_char '\n' m)))
        (C.messages ctl))

let unsat () =
  C.with_control (fun ctl ->
      C.add ctl "p. :- p.";
      C.ground ctl;
      (match C.optimal ctl with Some _ -> Fmt.pr "model?@." | None -> Fmt.pr "no model@.");
      let n, o = C.fold ctl ~init:0 (fun n _ -> n + 1) in
      Fmt.pr "%d models, %a@." n pp_outcome o)

(* Une échéance : treize pigeons dans treize trous, le treizième trou
   coûtant 1. Un modèle de coût 1 se trouve tout de suite ; prouver qu'on ne
   peut faire mieux, c'est prouver qu'on ne loge pas treize pigeons dans
   douze trous, hors de portée en une fraction de seconde. *)
let pigeons = {|
pigeon(1..13). hole(1..13).
1 { in(P, H) : hole(H) } 1 :- pigeon(P).
:- hole(H), 2 { in(P, H) : pigeon(P) }.
#minimize { 1, P : in(P, 13) }.
|}

let timeout () =
  C.with_control (fun ctl ->
      C.add ctl pigeons;
      C.ground ctl;
      (match C.best ~time_limit:0.2 ctl with
       | Some (m, o) ->
         Fmt.pr "best: cost=[%a] %a interrupted=%b@." Fmt.(list ~sep:(any ",") int) m.cost
           pp_outcome o o.interrupted
       | None -> Fmt.pr "no model@.");
      (* Sans le prouver, optimal refuse de conclure. *)
      match C.optimal ~time_limit:0.2 ctl with
      | _ -> Fmt.pr "optimal?@."
      | exception C.Error { code = C.Runtime; _ } -> Fmt.pr "optimal: not proven@.")

let report f =
  try f () with C.Error e ->
    Fmt.pr "Error %s@."
      (match e.code with C.Runtime -> "Runtime" | Logic -> "Logic"
                       | Bad_alloc -> "Bad_alloc" | Unknown -> "Unknown");
    List.iter (Fmt.pr "  %s@.") (String.split_on_char '\n' e.message)

let errors () =
  report (fun () -> C.with_control (fun ctl -> C.add ctl "p(."));
  report (fun () ->
      C.with_control ~args:[ "--models=1" ] (fun ctl ->
          C.add ctl "{ p(1..3) }. #maximize { X : p(X) }.";
          C.ground ctl;
          ignore (C.optimal ctl)));
  report (fun () -> ignore (C.create ~args:[ "--no-such-option" ] ()));
  report (fun () ->
      let ctl = C.create () in
      C.free ctl;
      C.free ctl;
      C.add ctl "p.");
  (* Une exception levée pendant le parcours ferme la résolution : le
     contrôle reste utilisable. *)
  C.with_control ~args:[ "--models=0" ] (fun ctl ->
      C.add ctl "{ p }.";
      C.ground ctl;
      (try ignore (C.fold ctl ~init:() (fun () _ -> failwith "stop")) with Failure m -> Fmt.pr "raised %s@." m);
      let n, _ = C.fold ctl ~init:0 (fun n _ -> n + 1) in
      Fmt.pr "then %d models@." n)

let () =
  match Sys.argv with
  | [| _; "version" |] -> let major, _, _ = C.version () in Fmt.pr "clingo %d.x@." major
  | [| _; "optimal" |] -> optimal ()
  | [| _; "all" |] -> all ()
  | [| _; "symbols" |] -> symbols ()
  | [| _; "unsat" |] -> unsat ()
  | [| _; "errors" |] -> errors ()
  | [| _; "timeout" |] -> timeout ()
  | _ -> prerr_endline "usage: clingo_demo (version|optimal|all|symbols|unsat|errors|timeout)"; exit 2
