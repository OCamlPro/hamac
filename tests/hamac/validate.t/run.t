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

Sorte de manifeste inconnue : LOAF l'accepte aujourd'hui sans rien dire (un
prédicat non déclaré est permis, défini par un seul fichier : un bloc mal
orthographié passe pour un prédicat intermédiaire), et Hamac ne lit que ses
sortes. Défaut signalé à LOAF : ce test changera avec lui.

  $ hamac validate unknown-block.loaf

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
  infra.loaf: service (name=web-api, runtime=http)
  infra.loaf: infrastructure (name=lab, backend=docker-compose)
