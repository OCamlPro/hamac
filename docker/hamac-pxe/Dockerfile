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

# ---- Stage : build from-source statique de qemu-img (fallback bmaptool) ----
# `qemu-img` sert de fallback dans pxe-build/init pour les profils/initrd
# pas encore migrés au chemin bmaptool (raw.zst + .bmap dérivés à l'avance,
# cf. doc/PROVISIONING_SPEC.md §3.1) — c'est le SEUL usage : conversion
# qcow2->raw purement locale, jamais de réseau/TLS. Le paquet apt
# `qemu-utils` embarquerait ~20 paquets de dépendances transitives (surtout
# TLS/PKCS#11 pour le support NBD-over-TLS, hors sujet ici — testé et
# rejeté, cf. HAMAC_PXE_FREEZE_INVESTIGATION.md). D'où un build from-source
# minimal, en désactivant tout ce qui n'est pas qcow2/raw.
#
# Alpine/musl plutôt que la même base que ipxe-builder (Ubuntu/glibc) :
# un lien vraiment statique avec glibc est notoirement peu fiable pour un
# projet de la taille de QEMU (problèmes connus autour de NSS/dlopen) ;
# musl s'y prête beaucoup mieux. C'est le même choix que
# tools/static-build/Dockerfile pour les binaires SIESTE eux-mêmes.
#
# N'atterrit PAS dans l'image Docker finale via COPY --from= comme
# ipxe-builder : le binaire produit ici doit finir DANS l'initramfs
# (initramfs-hybrid.gz), assemblée par le job CI build:hamac-pxe AVANT le
# `docker build` de ce Dockerfile. Le CI cible ce stage spécifiquement
# (`docker build --target qemu-img-builder`) et en extrait le binaire —
# voir .gitlab-ci.yml.
FROM alpine:3.21 AS qemu-img-builder
RUN apk add --no-cache \
      bash \
      build-base \
      meson \
      ninja-build \
      pkgconf \
      python3 \
      glib-dev \
      glib-static \
      pixman-dev \
      pixman-static \
      zlib-static \
      bzip2-static \
      perl \
      git \
      linux-headers \
      curl-dev \
      curl-static \
      openssl-dev \
      openssl-libs-static \
      nghttp2-dev \
      nghttp2-static \
      libssh2-dev \
      libssh2-static \
      brotli-dev \
      brotli-static \
      libidn2-dev \
      libidn2-static \
      libpsl-dev \
      libpsl-static \
      libunistring-dev \
      libunistring-static \
      zstd-dev \
      zstd-static
# Version pinnée pour reproductibilité (même logique que IPXE_GIT_COMMIT
# ci-dessus). À bumper volontairement, pas de dérive automatique.
ARG QEMU_GIT_TAG=v10.2.4
RUN git clone --depth 1 --branch "${QEMU_GIT_TAG}" https://github.com/qemu/qemu.git /usr/src/qemu
WORKDIR /usr/src/qemu
# --static + --disable-system/--disable-user : on ne veut QUE les outils
# (qemu-img, qemu-io...), pas les émulateurs. Tout le reste désactivé
# explicitement plutôt que de compter sur l'absence des libs dev
# correspondantes dans l'image de build — TLS/PKCS#11 (gnutls/nettle/
# gcrypt), réseau/affichage/son (curses/vnc/sdl/gtk/opengl/spice/alsa/oss/
# pa), stockage distant (rbd/glusterfs/libiscsi/libnfs), et le reste des
# à-côtés non pertinents pour une conversion qcow2->raw locale.
#
# --enable-curl (PAS désactivé, contrairement au reste) : pxe-build/init
# n'utilise PAS le driver curl aujourd'hui (le fallback qcow2 télécharge
# en local via wget puis convertit, pour garder la vérification sha256
# active — cf. commentaire dans pxe-build/init) — mais la capacité de
# streamer un qcow2 directement depuis une URL
# (`qemu-img convert -f qcow2 -O raw -t none <URL> <device>`, sans copie
# locale intermédiaire) est réellement buildée et testée statique+curl
# ci-dessous, prête si un futur profil a besoin de s'affranchir de l'espace
# tmpfs local (image nettement plus grosse, matériel avec peu de RAM). Le
# CDN Debian (cdimage.debian.org, via son miroir réel) supporte bien les
# requêtes HTTP Range nécessaires — vérifié directement (`curl -H "Range:
# ..."` → `206 Partial Content` correct), donc ce chemin fonctionnerait
# vraiment le jour où quelqu'un veut l'activer côté pxe-build/init.
#
# --enable-tools est nécessaire explicitement : meson.build a
# `have_tools = get_option('tools').disable_auto_if(not have_system).allowed()`
# — avec `tools` sur sa valeur par défaut `auto` ET `--disable-system`,
# have_tools reste faux et qemu-img n'est même pas déclaré comme cible
# ninja (découvert en testant : `ninja -t targets all` ne le listait pas
# du tout tant que ce flag manquait).
RUN ./configure \
      --static \
      --disable-system \
      --disable-user \
      --disable-bsd-user \
      --enable-tools \
      --enable-curl \
      --disable-guest-agent \
      --disable-docs \
      --disable-gnutls \
      --disable-nettle \
      --disable-gcrypt \
      --disable-curses \
      --disable-vnc \
      --disable-sdl \
      --disable-gtk \
      --disable-opengl \
      --disable-spice \
      --disable-usb-redir \
      --disable-libusb \
      --disable-brlapi \
      --disable-vde \
      --disable-netmap \
      --disable-pa \
      --disable-alsa \
      --disable-oss \
      --disable-cap-ng \
      --disable-seccomp \
      --disable-numa \
      --disable-rbd \
      --disable-glusterfs \
      --disable-libiscsi \
      --disable-libnfs \
      --disable-smartcard \
      --disable-virglrenderer \
      --disable-capstone \
      --disable-slirp \
 && ninja -C build qemu-img
# Build-testé de bout en bout (docker build --target qemu-img-builder,
# curl inclus) : lien statique complet réussi une fois zlib-static/
# bzip2-static/curl-static+sa propre chaîne de deps statiques (openssl/
# nghttp2/libssh2/brotli/libidn2/libpsl/libunistring/zstd, toutes ci-dessus)
# ajoutées — le lien échouait sinon sur "-lz"/"libbz2.so non-static"/
# "-lunistring" un par un au fil des tests. `file build/qemu-img` confirme
# "static-pie linked". Fonctionnellement vérifié : conversion qcow2->raw
# locale ET streaming direct via URL HTTP (driver curl, testé contre un
# vrai serveur HTTP local avec Range requests) donnent tous les deux un
# résultat identique octet pour octet à la source.

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
