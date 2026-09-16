Un manifeste de service valide est accepté, et `validate` en résume le kind :

  $ hamac validate service.yml
  service.yml: service (name=web, runtime=http)

Les erreurs sont rapportées avec le chemin YAML fautif, et `validate` sort en
échec — la CI ne doit pas passer sur un manifeste invalide.

Champ obligatoire absent :

  $ hamac validate missing-name.yml
  hamac: [ERROR] missing-name.yml: name: required field 'name' is missing
  [1]

Kind inconnu — le message énumère les kinds acceptés :

  $ hamac validate unknown-kind.yml
  hamac: [ERROR] unknown-kind.yml: kind: unknown manifest kind 'widget' (expected: service, stack, infrastructure, provisioning_profile, bundle)
  [1]

Type de champ incorrect, repéré jusque dans un élément de liste :

  $ hamac validate bad-port.yml
  hamac: [ERROR] bad-port.yml: ports.0.host: expected an integer
  [1]

Plusieurs fichiers en un appel : tous sont examinés, pas seulement le premier.

  $ hamac validate service.yml missing-name.yml
  service.yml: service (name=web, runtime=http)
  hamac: [ERROR] missing-name.yml: name: required field 'name' is missing
  [1]
