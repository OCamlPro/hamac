# hamac-pxe Docker image

Image PXE pour hamac-provisioning. Combine dnsmasq (mode proxy DHCP +
TFTP) avec un TFTP root pré-populé contenant `pxelinux.0`, le kernel
Alpine et l'initramfs hybride avec le init hamac.

Tag canonique : `registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0` + `latest`.

## Mode proxy DHCP

Cette image n'est PAS un DHCP server complet : elle tourne en mode
**proxy** (cf. dnsmasq doc), ce qui veut dire qu'elle **cohabite avec le
DHCP existant du LAN** (chez OCP-SI : la Turris/OpenWRT) :

- La Turris continue à attribuer les IPs (DHCP classique, intouché).
- hamac-pxe écoute en parallèle sur le même LAN et **répond uniquement
  aux requêtes PXE** (options 60/93/94/97, etc.).
- Le client PXE reçoit son IP de la Turris ET les infos boot
  (`boot file = pxelinux.0`) de hamac-pxe.
- Aucune reconfiguration de la Turris requise.

Conséquence : **l'image doit tourner en `network_mode: host`** (Docker
overlay/bridge ne sert pas le broadcast L2). C'est imposé par le
`docker-compose stack.yaml` chez OCP-SI.

## Build

```sh
./build.sh                                    # tag par défaut
./build.sh registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:dev   # tag custom
```

Le `build.sh` :
1. Vérifie la présence de `vmlinuz` + `initramfs-hybrid.gz` dans
   `tools/discovery-prototype/tftp/`. Si manquant, échoue avec une
   indication pour régénérer (cf. `e2e-hamac-test.sh`).
2. Copie ces fichiers dans le contexte Docker (`docker/hamac-pxe/tftp/`).
3. `docker build` avec deux tags (`:0.1.0` + `:latest`).
4. Smoke test : lance le container 3s avec une conf minimale et vérifie
   que dnsmasq ne crashe pas.

Les fichiers `vmlinuz` (~12 MB) et `initramfs-hybrid.gz` (~28 MB) ne sont
PAS commités au repo (cf. `.gitignore`). Le `build.sh` les recopie à
chaque run.

## Run

Local (test sans broadcast réel, juste valider la conf dnsmasq) :
```sh
docker run --rm \
  -e INTERFACE=lo \
  -e LISTEN_ADDRESS=127.0.0.1 \
  -e DISCOVERY_URL=http://example:8877 \
  registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0
```

Sur le LAN OCP (production, network host) :
```sh
docker run --network host --cap-add NET_ADMIN \
  -e INTERFACE=eth0 \
  -e DISCOVERY_URL=http://socrates.ocp.local:8877 \
  -e ALLOWED_MACS=aa:bb:cc:dd:ee:ff,11:22:33:44:55:66 \
  registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0
```

Variables d'environnement :

| Var | Défaut | Description |
|---|---|---|
| `INTERFACE` | `eth0` | Interface LAN sur le host (broadcast L2) |
| `LISTEN_ADDRESS` | `0.0.0.0` | IP du host sur laquelle écouter |
| `DISCOVERY_URL` | `http://10.99.0.1:8877` | URL discovery atteignable depuis les laptops à provisionner |
| `ALLOWED_MACS` | (vide) | CSV de MACs autorisées. **Si vide, répond à toute MAC qui demande PXE — déconseillé sur LAN partagé.** |
| `PXE_PROMPT` | `hamac-pxe boot` | Message au boot |
| `LOG_DHCP` | `0` | `1` = verbose DHCP/TFTP |

Le container a besoin de `cap_add: NET_ADMIN` pour binder sur :67/UDP.

## Sécurité

- Image privée, déploiement OCP-SI interne uniquement
- `ALLOWED_MACS` strict pour restreindre les hosts qui reçoivent une
  réponse PXE — important sur LAN partagé pour ne pas accidentellement
  intercepter le boot d'une autre machine OCP

## Push

```sh
docker login registry.ocamlpro.com    # creds via ansible vault chez OCP-SI
docker push registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:0.1.0
docker push registry.ocamlpro.com/ocamlpro/sieste/hamac-pxe:latest
```

## Voir aussi

- [`doc/OCPSI_DEPLOY_PLAN.md`](../../doc/OCPSI_DEPLOY_PLAN.md) : intégration OCP-SI
- [`tools/discovery-prototype/pxe-build/init`](../../tools/discovery-prototype/pxe-build/init) : init script du initramfs
