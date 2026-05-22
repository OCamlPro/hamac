#!/bin/sh
# Génère dnsmasq.conf + pxelinux.cfg/default à partir des env vars, puis
# lance dnsmasq en foreground.
#
# Env vars :
#   INTERFACE       : interface LAN (défaut: eth0)
#   DISCOVERY_URL   : URL atteignable depuis les laptops à provisionner
#                     (défaut: http://10.99.0.1:8877)
#   ALLOWED_MACS    : CSV de MACs autorisées. Vide = tout le monde
#                     (déconseillé sur LAN partagé).
#   LISTEN_ADDRESS  : IP du host sur laquelle écouter (défaut: 0.0.0.0)
#   PXE_PROMPT      : message affiché au boot PXE (défaut: "hamac-pxe boot")
#   LOG_DHCP        : "1" pour activer `log-dhcp` (verbose)
set -eu

INTERFACE="${INTERFACE:-eth0}"
DISCOVERY_URL="${DISCOVERY_URL:-http://10.99.0.1:8877}"
ALLOWED_MACS="${ALLOWED_MACS:-}"
LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
PXE_PROMPT="${PXE_PROMPT:-hamac-pxe boot}"
LOG_DHCP="${LOG_DHCP:-0}"

echo "[hamac-pxe] interface=$INTERFACE listen=$LISTEN_ADDRESS"
echo "[hamac-pxe] discovery=$DISCOVERY_URL"
if [ -n "$ALLOWED_MACS" ]; then
  echo "[hamac-pxe] allowed_macs=$ALLOWED_MACS (restrictive mode)"
else
  echo "[hamac-pxe] allowed_macs=<empty> (CAUTION: répond à toute MAC qui demande PXE)"
fi

# ---- pxelinux.cfg/default ---------------------------------------------------
# Le init de l'initrd lit /proc/cmdline et utilise sieste.discovery=
# pour atteindre le discovery server. C'est aussi là qu'on passe
# le hostname (sieste.hostname=).
cat > /tftp/pxelinux.cfg/default <<EOF
DEFAULT hamac
TIMEOUT 30
PROMPT 0

LABEL hamac
    KERNEL vmlinuz
    APPEND initrd=initramfs.img console=tty0 console=ttyS0 ip=dhcp sieste.discovery=$DISCOVERY_URL

LABEL local
    LOCALBOOT 0
EOF
echo "[hamac-pxe] pxelinux.cfg/default généré"

# ---- dnsmasq.conf -----------------------------------------------------------
{
  echo "# Généré par entrypoint.sh"
  echo "port=0"                       # désactive le DNS
  echo "interface=$INTERFACE"
  echo "bind-interfaces"
  echo "listen-address=$LISTEN_ADDRESS"
  echo ""
  echo "# Mode proxy DHCP : on cohabite avec le DHCP existant du LAN."
  echo "dhcp-no-override"
  echo "# Range proxy : on déduit le subnet de l'interface au runtime."
  echo "# Si le subnet est connu, remplacer ici."
  echo "dhcp-range=set:hamac-pxe,${LISTEN_ADDRESS},proxy"
  echo ""
  echo "# TFTP"
  echo "enable-tftp"
  echo "tftp-root=/tftp"
  echo ""
  echo "# Boot file annoncé à tous les PXE clients matchant 'hamac-pxe'"
  echo "dhcp-boot=tag:hamac-pxe,pxelinux.0"
  echo ""

  if [ "$LOG_DHCP" = "1" ]; then
    echo "log-dhcp"
  fi

  if [ -n "$ALLOWED_MACS" ]; then
    echo "# Restriction par MAC : seuls les hosts listés reçoivent une réponse PXE."
    echo "$ALLOWED_MACS" | tr ',' '\n' | while read -r mac; do
      mac=$(echo "$mac" | tr -d ' ')
      [ -z "$mac" ] && continue
      echo "dhcp-host=$mac,set:hamac-pxe"
    done
    echo "dhcp-ignore=tag:!hamac-pxe"
  fi
  echo ""
  echo "# Garder dnsmasq en foreground (Docker)"
  echo "keep-in-foreground"
  echo "log-queries"
} > /etc/dnsmasq.conf

echo "[hamac-pxe] dnsmasq.conf :"
echo "----"
cat /etc/dnsmasq.conf
echo "----"
echo ""
echo "[hamac-pxe] starting dnsmasq..."
exec dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon
