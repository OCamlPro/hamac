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
# Base paramétrable via PXE_BASE_IMAGE (build arg) : le paquet `ipxe` de
# Debian bookworm (12, oldstable) est figé sur un snapshot de janvier 2019
# (1.0.0+git-20190125.36a4c85-5.1), antérieur au support mature de
# LoadFile2 (chargement de l'initrd en mémoire pour l'EFI stub, requis par
# le boot UEFI réseau — cf. entrypoint.sh) — suspect principal d'un freeze
# silencieux constaté au boot UEFI sur un Framework Laptop 13 : `boot`
# s'exécute sans erreur côté iPXE, puis la machine se fige totalement
# (aucune sortie, aucune interaction).
#
# Debian trixie (13, stable depuis août 2025) fournit
# 1.21.1+git20250501.dad20602+dfsg-1 — snapshot de mai 2025, très en avance
# sur le support UEFI/LoadFile2. C'est la valeur par défaut ci-dessous.
# Pour tester une autre base (ex. retour à bookworm-slim en cas de
# régression) : `docker build --build-arg PXE_BASE_IMAGE=debian:bookworm-slim ...`
# (ou via `PXE_BASE_IMAGE=... ./build.sh`).
#
# Configuration au runtime via env vars (entrypoint.sh) :
#   INTERFACE         (ex: eth0) — interface LAN sur le host
#   DISCOVERY_URL     (ex: http://socrates.ocp.local:8877)
#   ALLOWED_MACS      (CSV : "aa:bb:..,cc:dd:..")
#   LISTEN_ADDRESS    (optionnel : IP sur laquelle écouter, sinon any)
#
# Le service doit tourner en network_mode: host sur le Swarm pour
# broadcaster en L2 (DHCP).

# Résolu : le test A/B ci-dessus a conclu que dnsmasq 2.90 (bookworm) et
# 2.91 (trixie) se comportaient IDENTIQUEMENT (silence total sur
# PXEClient:Arch:00007) — la version de dnsmasq n'y était pour rien. La
# vraie cause était l'absence de directives `pxe-service` dans
# entrypoint.sh (cf. son historique git). Retour à trixie par défaut,
# comme documenté plus haut : rien ne justifie plus de rester sur
# bookworm, dont le paquet ipxe est celui qu'on cherche justement à
# éviter (cf. lignes 11-18 ci-dessus).
ARG PXE_BASE_IMAGE=debian:trixie-slim
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
