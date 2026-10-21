Flux déclarés entre services et cloisonnement Bell-LaPadula.

`analytics` (zone internal) consomme `web_api` (zone public) : c'est une
lecture vers le bas, permise par le treillis. Le plan ouvre exactement ce flux ;
toute autre connexion entre zones reste refusée, et aucune zone ne peut ouvrir
de connexion vers une zone plus sensible.

  $ hamac plan analytics.yml payroll.yml web_api.yml | sed -n '/Firewall rules/,$p'
  Firewall rules:
    ALLOW internal -> public (analytics -> web_api)
    DENY internal -> secure (no read up)
    DENY public -> internal (no read up)
    DENY public -> secure (no read up)
    DENY secure -> internal (no declared flow)
    DENY secure -> public (no declared flow)
    Stateful: replies to an allowed connection pass.
  

`resolve` câble le flux : `{host}` et `{port}` désignent le service consommé.

  $ hamac resolve analytics.yml payroll.yml web_api.yml | sed -n '/Wiring/,$p'
  Wiring:
    analytics.api -> web_api (service)
      inject: API_URL=http://web_api:8080

En simulation, un nœud n'est branché que sur les réseaux des zones vers
lesquelles un flux déclaré l'autorise, avec une adresse fixe sur chacun. Le
filtrage suit l'état des connexions, en INPUT/OUTPUT et dans DOCKER-USER
(conteneurs) : `internal` n'ouvre vers `public` que le port de `web_api`, et
`public` n'accepte de nouvelle connexion du nœud `internal` que sur ce port.

  $ hamac simulate analytics.yml payroll.yml web_api.yml > /dev/null
  $ for n in internal public secure; do echo "node-$n-1:"; sed -n "/^  node-$n-1:/,/restart:/p" docker-compose.yml | sed -n '/networks:/,/restart:/p' | grep -E 'zone_|ipv4'; done
  node-internal-1:
        zone_internal:
          ipv4_address: 10.10.0.10
        zone_public:
          ipv4_address: 10.11.0.11
  node-public-1:
        zone_public:
          ipv4_address: 10.11.0.10
  node-secure-1:
        zone_secure:
          ipv4_address: 10.12.0.10
  $ grep iptables .hamac/init-node-internal-1.sh
  iptables -F DOCKER-USER
  iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I OUTPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A OUTPUT -d 10.11.0.0/24 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
  iptables -A DOCKER-USER -d 10.11.0.0/24 -p tcp -m conntrack --ctstate NEW --ctorigdstport 8080 -j ACCEPT
  iptables -A OUTPUT -d 10.11.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A INPUT -s 10.11.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -d 10.11.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -s 10.11.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A OUTPUT -d 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A INPUT -s 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -d 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -s 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -j RETURN
  $ grep iptables .hamac/init-node-public-1.sh
  iptables -F DOCKER-USER
  iptables -I INPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I OUTPUT 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -I DOCKER-USER 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  iptables -A INPUT -s 10.11.0.11 -p tcp --dport 8080 -m conntrack --ctstate NEW -j ACCEPT
  iptables -A DOCKER-USER -s 10.11.0.11 -p tcp -m conntrack --ctstate NEW --ctorigdstport 8080 -j ACCEPT
  iptables -A INPUT -s 10.11.0.11 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -s 10.11.0.11 -m conntrack --ctstate NEW -j DROP
  iptables -A OUTPUT -d 10.10.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A INPUT -s 10.10.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -d 10.10.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -s 10.10.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A OUTPUT -d 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A INPUT -s 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -d 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -s 10.12.0.0/24 -m conntrack --ctstate NEW -j DROP
  iptables -A DOCKER-USER -j RETURN

Une lecture vers le haut est refusée : `portal` (zone public) ne peut pas
consommer `payroll` (zone secure).

  $ hamac plan portal-read-up.yml payroll.yml
  hamac: [ERROR] portal-read-up.yml: consumes.0: [E040] portal (zone public) cannot consume payroll (zone secure): opening a connection to a more sensitive zone is a read up, forbidden by the Bell-LaPadula model. If payroll must expose data to zone public, have it push the declassified data to a service of that zone through a declared guard.
  [1]
  $ hamac simulate portal-read-up.yml payroll.yml
  hamac: [ERROR] [E040] portal (zone public) cannot consume payroll (zone secure): opening a connection to a more sensitive zone is a read up, forbidden by the Bell-LaPadula model. If payroll must expose data to zone public, have it push the declassified data to a service of that zone through a declared guard.
  [1]

Un flux vers un service absent de la stack est une erreur.

  $ hamac plan reporting-unknown.yml web_api.yml
  hamac: [ERROR] reporting-unknown.yml: consumes.0: [E020] reporting: consumes 'ledger': unknown service 'ledger' (not part of this stack)
  [1]
