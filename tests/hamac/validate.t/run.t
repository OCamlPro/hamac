Un manifeste de service valide est accepté, et `validate` en résume la sorte :

  $ hamac validate service.loaf
  service.loaf: service (name=web, runtime=http)

Les erreurs sont rapportées avec le fichier, la ligne et la colonne fautifs, et
`validate` sort en échec — la CI ne doit pas passer sur un manifeste invalide.
Ces fautes-là, le langage les refuse lui-même (codes `L…` de LOAF).

Champ obligatoire absent :

  $ hamac validate missing-runtime.loaf
  hamac: [ERROR] missing-runtime.loaf:7:1: [L007] service(api): field runtime has no value
  [1]

Sorte de manifeste inconnue : un bloc, et une instruction écrite dans un
bloc, utilisent un bloc et un champ déclarés ; LOAF refuse le reste (L001).

  $ hamac validate unknown-block.loaf
  hamac: [ERROR] unknown-block.loaf:7:1: [L001] widget(web). — widget is not declared: no block declaration of this name
  hamac: [ERROR] unknown-block.loaf:8:3: [L001] widget.runtime(web, http). — widget.runtime is not declared: its block declares no such field
  [1]

Valeur hors de la sorte du champ :

  $ hamac validate bad-port.loaf
  hamac: [ERROR] bad-port.loaf:9:3: [L002] service.port(web, "huit mille"): "huit mille" does not belong to sort int
  [1]

Plusieurs fichiers en un appel forment un ensemble, examiné en entier.

  $ hamac validate service.loaf missing-runtime.loaf
  service.loaf: service (name=web, runtime=http)
  hamac: [ERROR] missing-runtime.loaf:7:1: [L007] service(api): field runtime has no value
  [1]

Les règles de filtrage d'un manifeste d'infrastructure sont des faits typés :
une règle `allow` nomme le flux (consommateur, service consommé) qui la
justifie, les services nommés doivent exister.

  $ hamac validate infra.loaf
  infra.loaf: service (name=analytics, runtime=eventloop)
  infra.loaf: service (name=web_api, runtime=http)
  infra.loaf: infrastructure (name=lab, backend=docker_compose)
