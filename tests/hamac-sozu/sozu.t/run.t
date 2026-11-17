Provider Sozu (Hyper Open X, lot L4) : la configuration de routage de Sozu
est générée depuis les expositions (bloc exposure) des services des
manifestes — un listener par port d'écoute, un cluster et un frontend par
exposition, le service comme backend. Les routes protégées (étiquettes
security) sont rappelées en commentaire de chaque cluster : c'est la
validation Biscuit en bordure (hamac biscuit authorizers).

  $ R=../../..
  $ hamac sozu exposures $R/examples/hr-stack $R/providers
  hr-api api.rh.example.org:8080 http tls=acme path=/
  portal rh.example.org:8080 http tls=acme path=/

La configuration TOML complète :

  $ hamac sozu config $R/examples/hr-stack $R/providers
  # Configuration Sozu générée par hamac (provider hamac-sozu)
  # services exposés : hr-api, portal
  
  command_socket = "/run/sozu/command.sock"
  log_level = "info"
  worker_count = 1
  
  [[listeners]]
  address = "0.0.0.0:8080"
  protocol = "http"
  
  # routes protégées (validation Biscuit en bordure — hamac biscuit authorizers) :
  #   /employees/* [GET]
  #   /employees/salaries
  [clusters."hr-api"]
  protocol = "http"
  load_balancing = "ROUND_ROBIN"
  
  [[clusters."hr-api".frontends]]
  address = "0.0.0.0:8080"
  hostname = "api.rh.example.org"
  path = "/"
  # tls: acme (terminaison au déploiement, avec les certificats)
  
  [[clusters."hr-api".backends]]
  address = "hr-api:8080"
  backend_id = "hr-api"
  
  [clusters."portal"]
  protocol = "http"
  load_balancing = "ROUND_ROBIN"
  
  [[clusters."portal".frontends]]
  address = "0.0.0.0:8080"
  hostname = "rh.example.org"
  path = "/"
  # tls: acme (terminaison au déploiement, avec les certificats)
  
  [[clusters."portal".backends]]
  address = "portal:8080"
  backend_id = "portal"

L'adresse d'écoute et le socket de commande se règlent par options :

  $ hamac sozu config $R/examples/hr-stack $R/providers --listen-address 127.0.0.1 --command-socket /tmp/sozu.sock | sed -n '1,10p'
  # Configuration Sozu générée par hamac (provider hamac-sozu)
  # services exposés : hr-api, portal
  
  command_socket = "/tmp/sozu.sock"
  log_level = "info"
  worker_count = 1
  
  [[listeners]]
  address = "127.0.0.1:8080"
  protocol = "http"
