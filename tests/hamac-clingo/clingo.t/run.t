La liaison de libclingo (bibliothèque hamac-clingo), exercée par
clingo_demo.exe.

La version liée est de la série 5.

  $ ../clingo_demo.exe version
  clingo 5.x

Choix et optimisation : un sac à dos, valeur maximisée (priorité 2) puis
nombre d'objets minimisé (priorité 1). Le modèle optimal et son coût, les
modèles successifs de coût décroissant, et les modèles d'optimalité prouvée
du mode optN.

  $ ../clingo_demo.exe optimal
  optimal: take(b) take(d) cost=[-13,2]
  costs: [0,0] > [-8,1] > [-13,2], satisfiable=true exhausted=true
  proven: p(1) cost=[0]

Énumération de tous les modèles d'un choix (--models=0).

  $ ../clingo_demo.exe all
  p(1) cost=[]
  p(1) p(2) cost=[]
  p(1) p(3) cost=[]
  p(2) cost=[]
  p(2) p(3) cost=[]
  p(3) cost=[]
  6 models, satisfiable=true exhausted=true

Les symboles de toutes les sortes, lus comme valeurs OCaml ; une partie
paramétrée groundée deux fois ; le journal de clingo, recueilli et non
imprimé.

  $ ../clingo_demo.exe symbols
  s(41,42)
  t(1,-7,"a\"b",c,f(x,(1,2)),(),(u,),#inf,#sup,-g(2))
    Int 1
    Int -7
    Str "a\"b"
    Fun ("c", 0 args)
    Fun ("f", 2 args)
    Fun ("", 0 args)
    Fun ("", 1 args)
    Inf
    Sup
    Neg ("g", 1 args)
  atom_undefined: <block>:1:19-20: info: atom does not occur in any rule head:
  operation_undefined: <block>:1:1: info: operation undefined:

Un programme sans modèle.

  $ ../clingo_demo.exe unsat
  no model
  0 models, satisfiable=false exhausted=true

Les erreurs : programme mal formé (le détail vient du journal), optimum non
prouvé, option inconnue, contrôle libéré (free est idempotent) ; une
exception levée pendant le parcours des modèles ferme la résolution.

  $ ../clingo_demo.exe errors
  Error Runtime
    parsing failed
    <block>:1:3-4: error: syntax error, unexpected ., expecting ) or ;
  Error Runtime
    the search stopped before the optimum was proven (time limit, interruption, or --models)
  Error Logic
    In context '<libclingo>': unknown option: 'no-such-option'
  Error Logic
    the control has been freed
  raised stop
  then 2 models

Une échéance (time_limit) arrête la recherche : best rend le meilleur modèle
trouvé, dont l'optimalité n'est pas prouvée ; optimal refuse de conclure.

  $ ../clingo_demo.exe timeout
  best: cost=[1] satisfiable=true exhausted=false interrupted=true
  optimal: not proven
