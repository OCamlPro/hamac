# Image PXE pour hamac-provisioning.
#
# Contient :
#   - dnsmasq en mode proxy DHCP (cohabite avec le DHCP existant du LAN ;
#     ne répond que pour PXE)
#   - TFTP server intégré dnsmasq, sert /tftp/
#   - iPXE NBP : ipxe.efi (UEFI x86-64, buildé from-source — voir bloc
#     ci-dessous) + undionly.kpxe (BIOS legacy, paquet apt `ipxe`),
#     sélectionnés par architecture client (dnsmasq dhcp-match)
#   - kernel Debian (netboot installer) + initramfs-hybrid avec init hamac
#     (copiés au build — cf. .gitlab-ci.yml pour l'origine de ces fichiers ;
#     anciennement noyau Alpine `lts`, abandonné car ne produit aucune
#     sortie console sur un Framework Laptop 13/Meteor Lake, cf.
#     HAMAC_PXE_FREEZE_INVESTIGATION.md)
#
# iPXE UEFI x86-64 : buildé from-source (snp.efi) à un commit pinné précis,
# pas le paquet apt `ipxe`. Historique (cf. HAMAC_PXE_FREEZE_INVESTIGATION.md
# §3) : le paquet apt `ipxe` (1.21.1, janv. 2022) ne reconnaît jamais
# l'initrd sur ce Framework Laptop 13/Meteor Lake (bug LoadFile2/EFI, jamais
# de ligne "Loaded initrd..."). Une iPXE plus récente corrige ce point mais
# tombe sur un bug amont différent, toujours ouvert :
# https://github.com/ipxe/ipxe/issues/1372 ("iPXE hangs at EFI:Stub Measured
# initrd data into PCR 9") — freeze après le handoff EFI stub, identique
# avec `ipxe.efi`, `snponly.efi` ET `snp.efi` (contrairement à ce qu'un
# rapporteur amont affirmait, `snp.efi` ne corrige RIEN sur ce matériel,
# testé et confirmé). La vraie résolution : bisect real-hardware entre un
# commit ancien confirmé bon et master confirmé mauvais — voir
# `IPXE_GIT_COMMIT` ci-dessous et §3/§4 du doc. On continue à builder
# `snp.efi` (pas `ipxe.efi`) simplement parce que c'est déjà le variant en
# place, pas parce qu'il aurait un effet sur ce bug précis.
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

# ---- Stage 1 : build from-source de snp.efi (iPXE) --------------------------
# Commit pinné pour reproductibilité (même logique que les fichiers Alpine/
# Debian/busybox-static pinnés par sha256 dans .gitlab-ci.yml) — testé et
# validé manuellement (build local + smoke test) avant de pinner cette
# valeur ici. À bumper volontairement si besoin (nouveau bugfix amont à
# récupérer, etc.), pas de mécanisme de dérive automatique comme pour les
# URLs "current" de Debian.
FROM ${PXE_BASE_IMAGE} AS ipxe-builder
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      git \
      build-essential \
      perl \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Résultat du bisect real-hardware (HAMAC_PXE_FREEZE_INVESTIGATION.md §3) :
# premier commit testé entre fbbdc3926 (2022-01-13, connu bon) et 404588d
# (master, connu mauvais / ipxe/ipxe#1372) — boote proprement jusqu'au
# shell réel sur le Framework, retenu tel quel plutôt que de continuer à
# resserrer le bisect. À bumper volontairement si besoin (nouveau bugfix
# amont à récupérer, etc.), pas de mécanisme de dérive automatique comme
# pour les URLs "current" de Debian.
ARG IPXE_GIT_COMMIT=0edbc4c0824e54e3fe52d266c0dff50cfff59e8a
RUN git clone https://github.com/ipxe/ipxe.git /usr/src/ipxe \
 && cd /usr/src/ipxe \
 && git checkout "${IPXE_GIT_COMMIT}" \
 && cd src \
 && make NO_WERROR=1 bin-x86_64-efi/snp.efi
# NO_WERROR=1 : le binutils moderne de l'image de build est plus strict que
# ce que le -Werror historique d'iPXE tolère (avertissements sur du code de
# prefix BIOS legacy non utilisé par notre cible EFI) — sans ça le build
# casse sur des warnings sans rapport avec snp.efi lui-même.

# ---- Stage 2 : image finale --------------------------------------------------
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
# undionly.kpxe (BIOS legacy) vient toujours du paquet apt `ipxe` — aucun
# problème constaté sur ce chemin, pas de raison de le builder from-source
# aussi. ipxe.efi (UEFI x86-64) vient du stage `ipxe-builder` ci-dessus
# (snp.efi renommé — voir le commentaire en tête de fichier).
RUN mkdir -p /tftp \
 && cp /usr/lib/ipxe/undionly.kpxe /tftp/
COPY --from=ipxe-builder /usr/src/ipxe/src/bin-x86_64-efi/snp.efi /tftp/ipxe.efi

# Kernel et initramfs copiés depuis le contexte de build
# (générés par les scripts tools/discovery-prototype/)
COPY tftp/vmlinuz /tftp/vmlinuz
COPY tftp/initramfs-hybrid.gz /tftp/initramfs.img

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# dnsmasq écoute sur :67 (DHCP) et :69 (TFTP)
EXPOSE 67/udp 69/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
