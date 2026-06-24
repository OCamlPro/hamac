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
