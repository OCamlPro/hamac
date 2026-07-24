# Image PXE pour hamac-provisioning.
#
# Contient :
#   - dnsmasq en mode proxy DHCP (cohabite avec le DHCP existant du LAN ;
#     ne répond que pour PXE)
#   - TFTP server intégré dnsmasq, sert /tftp/
#   - iPXE NBP : ipxe.efi (UEFI x86-64) + undionly.kpxe (BIOS legacy),
#     sélectionnés par architecture client (dnsmasq dhcp-match)
#   - kernel Alpine + initramfs-hybrid avec init hamac (copiés au build)
#
# Base paramétrable via PXE_BASE_IMAGE (build arg). Historique de cette
# valeur (voir aussi entrypoint.sh et son historique git) :
#
#   - Debian bookworm (12) : paquet `ipxe` figé sur un snapshot de janvier
#     2019 (1.0.0+git-20190125.36a4c85-5.1), antérieur au support mature
#     de LoadFile2 (chargement de l'initrd en mémoire pour l'EFI stub,
#     requis par le boot UEFI réseau) — cause confirmée d'un freeze
#     silencieux après le chargement de l'initramfs sur un Framework
#     Laptop 13. En revanche dnsmasq 2.90 (bookworm) gère correctement
#     l'échange PXE port 4011 (proxy-DHCP boot server discovery).
#
#   - Debian trixie (13) : paquet `ipxe` très à jour
#     (1.21.1+git20250501.dad20602+dfsg-1, mai 2025), qui corrige le
#     freeze ci-dessus. Mais dnsmasq 2.91 (trixie) a un bug confirmé sur
#     ce même échange port 4011 : recvmsg() de la requête du client, puis
#     dnsmasq part en boucle infinie (100% CPU, `docker stats`) sans
#     jamais répondre ni redevenir responsive — un seul client atteignant
#     ce stade bloque le service pour toute machine suivante jusqu'à
#     redémarrage manuel. Confirmé absent sur dnsmasq 2.90 via A/B test
#     (strace + docker stats, mêmes entrypoint.sh/pxe-service des deux
#     côtés).
#
#   - Aucune des deux versions de Debian ne fournit donc à la fois un
#     ipxe récent ET un dnsmasq sans ce bug. Ubuntu noble (24.04 LTS)
#     fournit dnsmasq 2.90-2ubuntu0.4 (même version que bookworm, donc
#     sans le bug port 4011) ET ipxe 1.21.1+git-20220113.fbbdc3926
#     (janvier 2022, largement postérieur au support LoadFile2/UEFI) —
#     les deux problèmes évités sans build iPXE from-source. C'est la
#     valeur par défaut ci-dessous.
#
# Pour tester une autre base : `docker build --build-arg
# PXE_BASE_IMAGE=debian:bookworm-slim ...` (ou via `PXE_BASE_IMAGE=...
# ./build.sh`).
#
# Configuration au runtime via env vars (entrypoint.sh) :
#   INTERFACE         (ex: eth0) — interface LAN sur le host
#   DISCOVERY_URL     (ex: http://socrates.ocp.local:8877)
#   ALLOWED_MACS      (CSV : "aa:bb:..,cc:dd:..")
#   LISTEN_ADDRESS    (optionnel : IP sur laquelle écouter, sinon any)
#
# Le service doit tourner en network_mode: host sur le Swarm pour
# broadcaster en L2 (DHCP).
ARG PXE_BASE_IMAGE=ubuntu:noble
FROM ${PXE_BASE_IMAGE}

LABEL org.opencontainers.image.title="hamac-pxe" \
      org.opencontainers.image.description="PXE proxy DHCP + TFTP for hamac provisioning : serves iPXE (UEFI+BIOS) + kernel + initramfs to bare-metal hosts" \
      org.opencontainers.image.source="https://gitlab.ocamlpro.com/OCamlPro/sieste" \
      org.opencontainers.image.licenses="proprietary" \
      org.opencontainers.image.authors="OCamlPro <contact@ocamlpro.com>" \
      org.opencontainers.image.version="0.1.0"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      dnsmasq \
      ipxe \
      iproute2 \
      ca-certificates \
      curl \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# Préparer le tftp-root avec les NBP iPXE (UEFI + BIOS).
# Le paquet Debian `ipxe` fournit /usr/lib/ipxe/{ipxe.efi,undionly.kpxe}.
RUN mkdir -p /tftp \
 && cp /usr/lib/ipxe/ipxe.efi      /tftp/ \
 && cp /usr/lib/ipxe/undionly.kpxe /tftp/

# Kernel et initramfs copiés depuis le contexte de build
# (générés par les scripts tools/discovery-prototype/)
COPY tftp/vmlinuz /tftp/vmlinuz
COPY tftp/initramfs-hybrid.gz /tftp/initramfs.img

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# dnsmasq écoute sur :67 (DHCP) et :69 (TFTP)
EXPOSE 67/udp 69/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
