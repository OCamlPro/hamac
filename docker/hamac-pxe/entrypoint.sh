#!/bin/sh
# Génère dnsmasq.conf + pxelinux.cfg/default à partir des env vars, puis
# lance dnsmasq + un sidecar qui synchronise la whitelist MAC depuis le
# discovery server.
#
# Env vars :
#   INTERFACE         : interface LAN (défaut: eth0)
#   DISCOVERY_URL     : URL atteignable depuis l'image (pour le polling
#                       sidecar) — défaut: http://tasks.hamac-discovery:8877
#   PXE_DISCOVERY_URL : URL atteignable depuis les laptops PXE — défaut:
#                       DISCOVERY_URL. Sur le Swarm OCP-SI, c'est par ex.
#                       http://socrates.intranet.ocamlpro.com:8877.
#   ALLOWED_MACS      : CSV de MACs (compat backward, déprécié). Si fourni,
#                       elles sont injectées au démarrage en plus de celles
#                       polled depuis le discovery.
#   LISTEN_ADDRESS    : IP du host sur laquelle écouter (défaut: 0.0.0.0)
#   POLL_INTERVAL     : période (s) de poll du discovery (défaut: 30)
#   LOG_DHCP          : "1" pour activer `log-dhcp` (verbose)
set -eu

INTERFACE="${INTERFACE:-eth0}"
DISCOVERY_URL="${DISCOVERY_URL:-http://tasks.hamac-discovery:8877}"
PXE_DISCOVERY_URL="${PXE_DISCOVERY_URL:-$DISCOVERY_URL}"
ALLOWED_MACS="${ALLOWED_MACS:-}"
LISTEN_ADDRESS="${LISTEN_ADDRESS:-0.0.0.0}"
POLL_INTERVAL="${POLL_INTERVAL:-30}"
LOG_DHCP="${LOG_DHCP:-0}"

# Adresse utilisée par dnsmasq pour le mode proxy DHCP : DOIT être une IP du
# subnet à servir (pas 0.0.0.0, sinon dnsmasq logue "no address range
# available" et n'offre aucun boot file). Si DHCP_PROXY_ADDRESS n'est pas
# fourni, on la déduit de l'interface au runtime.
DHCP_PROXY_ADDRESS="${DHCP_PROXY_ADDRESS:-}"
if [ -z "$DHCP_PROXY_ADDRESS" ]; then
  DHCP_PROXY_ADDRESS=$(ip -4 -o addr show "$INTERFACE" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -1)
fi
if [ -z "$DHCP_PROXY_ADDRESS" ]; then
  echo "[hamac-pxe] WARN: impossible de déduire l'IP de $INTERFACE, fallback 0.0.0.0"
  DHCP_PROXY_ADDRESS=0.0.0.0
fi

ALLOWED_MACS_FILE=/etc/dnsmasq.d/allowed-macs.conf
mkdir -p /etc/dnsmasq.d

echo "[hamac-pxe] interface=$INTERFACE listen=$LISTEN_ADDRESS proxy_addr=$DHCP_PROXY_ADDRESS"
echo "[hamac-pxe] discovery (sidecar poll)=$DISCOVERY_URL"
echo "[hamac-pxe] discovery (passed to PXE clients)=$PXE_DISCOVERY_URL"
echo "[hamac-pxe] poll_interval=${POLL_INTERVAL}s"

# ---- Script iPXE de second étage --------------------------------------------
# Chaîne de boot : le firmware (UEFI ou BIOS) charge d'abord le NBP iPXE
# (ipxe.efi / undionly.kpxe) servi par dnsmasq. iPXE refait un DHCP ; dnsmasq
# le reconnaît (user-class "iPXE") et lui renvoie ce script, qui charge le
# kernel + initramfs (toujours en TFTP) et boote. Le init lit /proc/cmdline
# pour sieste.discovery= (URL publique atteignable depuis le client).
# NB : on hardcode l'IP du serveur TFTP (= cette machine) au lieu de
# \${next-server}. En mode proxy DHCP, le bail (et donc next-server côté
# iPXE) vient du vrai DHCP du LAN, PAS de nous — \${next-server} pointerait
# vers le mauvais serveur. $DHCP_PROXY_ADDRESS est notre IP sur $INTERFACE.
# IMPORTANT : ne PAS mettre initrd=initramfs.img sur la ligne kernel. En
# netboot UEFI, l'EFI stub tenterait de charger l'initrd via file I/O EFI
# (inexistant en réseau) -> hang sur "EFI stub: Loaded initrd from command
# line option". On utilise UNIQUEMENT la directive `initrd` d'iPXE, qui le
# charge en mémoire (protocole LoadFile2 repris par l'EFI stub).
# console=tty0 en dernier => /dev/console = écran physique.
cat > /tftp/boot.ipxe <<EOF
#!ipxe
echo hamac-pxe : chargement du live installer...
kernel tftp://$DHCP_PROXY_ADDRESS/vmlinuz console=ttyS0 console=tty0 ip=dhcp sieste.discovery=$PXE_DISCOVERY_URL
initrd tftp://$DHCP_PROXY_ADDRESS/initramfs.img
boot
EOF
echo "[hamac-pxe] boot.ipxe généré (tftp server=$DHCP_PROXY_ADDRESS)"

# ---- Seed initial du fichier dhcp-hostsfile -------------------------------
# Si ALLOWED_MACS (compat) est non vide, on initialise le fichier avec ces
# MACs. Le sidecar le remplacera ensuite par le contenu de l'API discovery
# (les deux sources de vérité ne devraient pas coexister en prod : le but
# est de migrer entièrement vers l'API).
: > "$ALLOWED_MACS_FILE"
if [ -n "$ALLOWED_MACS" ]; then
  echo "[hamac-pxe] (compat) ALLOWED_MACS env var: $ALLOWED_MACS"
  echo "$ALLOWED_MACS" | tr ',' '\n' | while read -r mac; do
    mac=$(echo "$mac" | tr -d ' ' | tr 'A-Z' 'a-z')
    [ -z "$mac" ] && continue
    echo "$mac,set:hamac-pxe" >> "$ALLOWED_MACS_FILE"
  done
fi

# ---- dnsmasq.conf -----------------------------------------------------------
{
  echo "# Généré par entrypoint.sh"
  echo "port=0"                       # désactive le DNS
  echo "interface=$INTERFACE"
  echo "bind-interfaces"
  echo "listen-address=$LISTEN_ADDRESS"
  echo ""
  echo "# Mode proxy DHCP : on cohabite avec le DHCP existant du LAN."
  echo "# L'adresse DOIT être dans le subnet servi (pas 0.0.0.0)."
  echo "dhcp-no-override"
  echo "dhcp-range=set:hamac-pxe,${DHCP_PROXY_ADDRESS},proxy"
  echo ""
  echo "# TFTP"
  echo "enable-tftp"
  echo "tftp-root=/tftp"
  echo ""
  echo "# Chaîne de boot iPXE, sélection par architecture client :"
  echo "#   arch 7/9 = UEFI x86-64  -> ipxe.efi"
  echo "#   arch 0   = BIOS legacy  -> undionly.kpxe"
  echo "# Une fois iPXE chargé (user-class iPXE), on lui sert le script boot.ipxe"
  echo "# au lieu de re-servir le NBP (évite la boucle de chainload)."
  echo "dhcp-userclass=set:ipxe,iPXE"
  echo "dhcp-match=set:efi64,option:client-arch,7"
  echo "dhcp-match=set:efi64,option:client-arch,9"
  echo "dhcp-boot=tag:hamac-pxe,tag:ipxe,boot.ipxe"
  echo "dhcp-boot=tag:hamac-pxe,tag:!ipxe,tag:efi64,ipxe.efi"
  echo "dhcp-boot=tag:hamac-pxe,tag:!ipxe,undionly.kpxe"
  echo ""
  echo "# Whitelist MAC chargée depuis $ALLOWED_MACS_FILE — rechargée"
  echo "# automatiquement par dnsmasq au SIGHUP (envoyé par le sidecar"
  echo "# quand le contenu change)."
  echo "dhcp-hostsfile=$ALLOWED_MACS_FILE"
  echo "dhcp-ignore=tag:!hamac-pxe"
  echo ""
  [ "$LOG_DHCP" = "1" ] && echo "log-dhcp"
  echo "# Foreground (PID dans /var/run/dnsmasq.pid pour le SIGHUP du sidecar)"
  echo "keep-in-foreground"
  echo "pid-file=/var/run/dnsmasq.pid"
  echo "log-queries"
} > /etc/dnsmasq.conf

echo "[hamac-pxe] dnsmasq.conf généré"

# ---- Sidecar : poll discovery → /etc/dnsmasq.d/allowed-macs.conf -----------
# Boucle en background. Toutes les POLL_INTERVAL secondes, fetch le contenu
# dnsmasq-hostsfile depuis le discovery server. Si le contenu diffère du
# fichier actuel, le remplacer et envoyer SIGHUP à dnsmasq.
allowed_macs_sync() {
  TMP=/tmp/allowed-macs.new
  while :; do
    if curl -sf --max-time 5 \
        "$DISCOVERY_URL/api/allowed-macs/dnsmasq-hostsfile" -o "$TMP" 2>/dev/null
    then
      if ! cmp -s "$TMP" "$ALLOWED_MACS_FILE"; then
        N=$(wc -l < "$TMP" 2>/dev/null || echo 0)
        echo "[hamac-pxe.sync] whitelist changed ($N entries), reloading dnsmasq"
        cp "$TMP" "$ALLOWED_MACS_FILE"
        if [ -f /var/run/dnsmasq.pid ]; then
          kill -HUP "$(cat /var/run/dnsmasq.pid)" 2>/dev/null || true
        fi
      fi
    else
      echo "[hamac-pxe.sync] discovery unreachable, keeping current whitelist"
    fi
    sleep "$POLL_INTERVAL"
  done
}
allowed_macs_sync &
SYNC_PID=$!
echo "[hamac-pxe] sync sidecar started (pid $SYNC_PID, poll=${POLL_INTERVAL}s)"

# Stopper proprement le sidecar quand dnsmasq exit
trap 'kill $SYNC_PID 2>/dev/null || true' EXIT

echo "[hamac-pxe] starting dnsmasq..."
exec dnsmasq --conf-file=/etc/dnsmasq.conf --no-daemon
