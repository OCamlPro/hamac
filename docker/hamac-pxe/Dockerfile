# Image PXE pour hamac-provisioning.
#
# Contient :
#   - dnsmasq en mode proxy DHCP (cohabite avec le DHCP existant du LAN ;
#     ne répond que pour PXE)
#   - TFTP server intégré dnsmasq, sert /tftp/
#   - pxelinux.0 + modules syslinux pour le chainload
#   - kernel Alpine + initramfs-hybrid avec init hamac (copiés au build)
#
# Configuration au runtime via env vars (entrypoint.sh) :
#   INTERFACE         (ex: eth0) — interface LAN sur le host
#   DISCOVERY_URL     (ex: http://socrates.ocp.local:8877)
#   ALLOWED_MACS      (CSV : "aa:bb:..,cc:dd:..")
#   LISTEN_ADDRESS    (optionnel : IP sur laquelle écouter, sinon any)
#
# Le service doit tourner en network_mode: host sur le Swarm pour
# broadcaster en L2 (DHCP).

FROM debian:bookworm-slim

LABEL org.opencontainers.image.title="hamac-pxe" \
      org.opencontainers.image.description="PXE proxy DHCP + TFTP for hamac provisioning : serves kernel + initramfs + pxelinux to bare-metal hosts" \
      org.opencontainers.image.source="https://gitlab.ocamlpro.com/OCamlPro/sieste" \
      org.opencontainers.image.licenses="proprietary" \
      org.opencontainers.image.authors="OCamlPro <contact@ocamlpro.com>" \
      org.opencontainers.image.version="0.1.0"

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      dnsmasq \
      pxelinux \
      syslinux-common \
      ca-certificates \
      curl \
      tzdata \
 && rm -rf /var/lib/apt/lists/*

# Préparer le tftp-root avec pxelinux.0 + modules
RUN mkdir -p /tftp/pxelinux.cfg \
 && cp /usr/lib/PXELINUX/pxelinux.0 /tftp/ \
 && cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /tftp/ \
 && cp /usr/lib/syslinux/modules/bios/libutil.c32 /tftp/ 2>/dev/null || true \
 && cp /usr/lib/syslinux/modules/bios/menu.c32 /tftp/ 2>/dev/null || true \
 && cp /usr/lib/syslinux/modules/bios/libcom32.c32 /tftp/ 2>/dev/null || true

# Kernel et initramfs copiés depuis le contexte de build
# (générés par les scripts tools/discovery-prototype/)
COPY tftp/vmlinuz /tftp/vmlinuz
COPY tftp/initramfs-hybrid.gz /tftp/initramfs.img

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# dnsmasq écoute sur :67 (DHCP) et :69 (TFTP)
EXPOSE 67/udp 69/udp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
