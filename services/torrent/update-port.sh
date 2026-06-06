#!/bin/sh
# Hook gluetun -> Transmission RPC.
#
# Appele par gluetun a chaque setup/changement de port-forwarding via
# VPN_PORT_FORWARDING_UP_COMMAND="/bin/sh /scripts/update-port.sh {{PORT}}".
# Tourne dans le namespace reseau de gluetun, donc 127.0.0.1:9091 = Transmission
# (qui partage le meme namespace via network_mode: service:gluetun).
#
# Transmission RPC est CSRF-protegee : il faut d'abord recuperer le
# X-Transmission-Session-Id via une 1ere requete (qui repond 409), puis
# refaire la requete avec ce header. wget de BusyBox (present dans gluetun
# image alpine-based) supporte --header et --post-data, on s'en sert.

set -e

PORT="$1"
if [ -z "$PORT" ]; then
  echo "[update-port] ERREUR: port manquant en arg" >&2
  exit 1
fi

RPC="http://127.0.0.1:9091/transmission/rpc"

# Step 1 : GET pour capturer le session-id (Transmission repond 409 avec le
# header X-Transmission-Session-Id, qu'il faut re-injecter dans la prochaine
# requete). On ignore le exit code 8 de wget (= HTTP 4xx, attendu ici).
SID=$(wget -q -S -O /dev/null "$RPC" 2>&1 \
  | sed -nE 's/^[[:space:]]*X-Transmission-Session-Id:[[:space:]]*(.+)$/\1/p' \
  | tr -d '\r')

if [ -z "$SID" ]; then
  echo "[update-port] ERREUR: pas de session-id (Transmission down ?)" >&2
  exit 1
fi

# Step 2 : POST avec le session-id et le payload de session-set
PAYLOAD="{\"method\":\"session-set\",\"arguments\":{\"peer-port\":${PORT},\"peer-port-random-on-start\":false}}"

if ! wget -q -O /dev/null \
  --header="X-Transmission-Session-Id: $SID" \
  --header="Content-Type: application/json" \
  --post-data="$PAYLOAD" \
  "$RPC"; then
  echo "[update-port] ERREUR: POST session-set a echoue" >&2
  exit 1
fi

echo "[update-port] $(date -Is) Transmission peer-port -> $PORT"
