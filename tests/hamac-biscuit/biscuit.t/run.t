Provider Biscuit (Hyper Open X, lot L3) : les étiquettes de route des
manifestes (bloc security, champs blp:: et rbac:: ajoutés par les modèles de
sécurité des patrons) sont traduites en autoriseurs Datalog Biscuit, que la
bordure applique avant de transmettre la requête.

  $ R=../../..
  $ hamac biscuit routes $R/examples/hr-stack $R/providers
  hr_api /employees/* [GET]
  hr_api /employees/salaries
  hr_api /health public

L'autoriseur d'une route combine les trois dimensions du treillis MLS :
classification (pas de lecture vers le haut — comparaison d'entiers sur le
rang du niveau déclaré par le patron), compartiments (besoin d'en connaître —
un check par catégorie) et rôles (clearance disjonctive — une jointure
Datalog, pas une liste plate).

  $ hamac biscuit authorizer $R/examples/hr-stack $R/providers --service hr_api --route /employees/salaries
  // Autoriseur Biscuit généré par hamac (provider hamac-biscuit)
  // service: hr_api
  // route: /employees/salaries
  //
  // (1) pas de lecture vers le haut : le niveau du sujet domine confidential (rang 3)
  check if clearance_level($l), $l >= 3;
  // (2) besoin d'en connaître : le sujet détient le compartiment "finance"
  check if compartment("finance");
  // (2) besoin d'en connaître : le sujet détient le compartiment "rh"
  check if compartment("rh");
  // (3) clearance disjonctive ("admin" ou "comptable") : au moins un rôle, par jointure Datalog
  valid_role("admin");
  valid_role("comptable");
  authorized_role($r) <- role($r), valid_role($r);
  check if authorized_role($r);
  allow if true;

Une route publique n'exige aucun jeton :

  $ hamac biscuit authorizer $R/examples/hr-stack $R/providers --service hr_api --route /health
  // Autoriseur Biscuit généré par hamac (provider hamac-biscuit)
  // service: hr_api
  // route: /health
  //
  // route publique : aucun jeton exigé.
  allow if true;

Tous les autoriseurs d'un service, un par route :

  $ hamac biscuit authorizers $R/examples/hr-stack $R/providers --service hr_api
  // Autoriseur Biscuit généré par hamac (provider hamac-biscuit)
  // service: hr_api
  // route: /employees/*
  // méthodes: GET (le filtrage par méthode est appliqué par la bordure, au routage)
  //
  // (1) pas de lecture vers le haut : le niveau du sujet domine internal (rang 2)
  check if clearance_level($l), $l >= 2;
  // (2) besoin d'en connaître : le sujet détient le compartiment "rh"
  check if compartment("rh");
  // (3) clearance disjonctive ("admin" ou "rh") : au moins un rôle, par jointure Datalog
  valid_role("admin");
  valid_role("rh");
  authorized_role($r) <- role($r), valid_role($r);
  check if authorized_role($r);
  allow if true;
  
  // Autoriseur Biscuit généré par hamac (provider hamac-biscuit)
  // service: hr_api
  // route: /employees/salaries
  //
  // (1) pas de lecture vers le haut : le niveau du sujet domine confidential (rang 3)
  check if clearance_level($l), $l >= 3;
  // (2) besoin d'en connaître : le sujet détient le compartiment "finance"
  check if compartment("finance");
  // (2) besoin d'en connaître : le sujet détient le compartiment "rh"
  check if compartment("rh");
  // (3) clearance disjonctive ("admin" ou "comptable") : au moins un rôle, par jointure Datalog
  valid_role("admin");
  valid_role("comptable");
  authorized_role($r) <- role($r), valid_role($r);
  check if authorized_role($r);
  allow if true;
  
  // Autoriseur Biscuit généré par hamac (provider hamac-biscuit)
  // service: hr_api
  // route: /health
  //
  // route publique : aucun jeton exigé.
  allow if true;

Le bloc autorité d'un jeton : la clearance du sujet, le niveau traduit en
rang par les niveaux déclarés du patron :

  $ hamac biscuit token $R/examples/hr-stack $R/providers --user alice --level confidential --categories rh,finance --roles comptable
  // Bloc autorité Biscuit — clearance du sujet (émis par le service d'auth)
  user("alice");
  clearance_level(3); // confidential
  compartment("rh");
  compartment("finance");
  role("comptable");

Sans fichiers, le niveau est un rang littéral :

  $ hamac biscuit token --user bob --level 1 --roles rh
  // Bloc autorité Biscuit — clearance du sujet (émis par le service d'auth)
  user("bob");
  clearance_level(1); // 1
  role("rh");

Un niveau que les patrons ne déclarent pas est refusé :

  $ hamac biscuit token $R/examples/hr-stack $R/providers --user eve --level topsecret
  hamac: [ERROR] biscuit: level "topsecret" is not declared by the patterns
  [1]

Un service absent des fichiers est refusé :

  $ hamac biscuit authorizer $R/examples/hr-stack $R/providers --service nope --route /x
  hamac: [ERROR] biscuit: no service "nope" in the files
  [1]

Test de propriété : sur le treillis fini de l'exemple (niveaux, catégories
et rôles déclarés par le patron), tous les sujets possibles sont énumérés ;
l'autoriseur généré, évalué par clingo, doit accepter exactement les accès
permis par le treillis MLS.

  $ ../property.exe $R
  96 sujets × 3 routes = 288 décisions : l'autoriseur Biscuit généré accepte exactement les accès permis par le treillis MLS.
