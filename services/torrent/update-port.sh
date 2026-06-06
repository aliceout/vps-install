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
# refaire la requete avec ce header. Si l'auth Basic est activee
# (TRANSMISSION_USER/PASS settes dans le container env), on ajoute aussi
# le header Authorization aux 2 requetes.

set -e

PORT="$1"
if [ -z "$PORT" ]; then
  echo "[update-port] ERREUR: port manquant en arg" >&2
  exit 1
fi

RPC="http://127.0.0.1:9091/transmission/rpc"

# Auth header optionnelle : si TRANSMISSION_USER set, on encode user:pass en
# base64 et on l'ajoute aux requetes. BusyBox base64 dispo dans gluetun (alpine).
AUTH_ARG=""
if [ -n "${TRANSMISSION_USER:-}" ]; then
  AUTH_B64=$(printf '%s:%s' "$TRANSMISSION_USER" "${TRANSMISSION_PASS:-}" | base64 -w0 2>/dev/null \
             || printf '%s:%s' "$TRANSMISSION_USER" "${TRANSMISSION_PASS:-}" | base64 | tr -d '\n')
  AUTH_ARG="--header=Authorization: Basic $AUTH_B64"
fi

# Retry loop : Transmission peut ne pas etre encore up quand gluetun appelle
# le hook (gluetun: healthy + tunnel up + port negocie en quelques sec,
# Transmission demarre apres via depends_on). On laisse 60s pour qu'il
# devienne reachable, sinon on bail.
SID=""
for i in $(seq 1 30); do
  SID=$(wget -q -S -O /dev/null ${AUTH_ARG:+"$AUTH_ARG"} "$RPC" 2>&1 \
    | sed -nE 's/^[[:space:]]*X-Transmission-Session-Id:[[:space:]]*(.+)$/\1/p' \
    | tr -d '\r')
  [ -n "$SID" ] && break
  sleep 2
done

if [ -z "$SID" ]; then
  echo "[update-port] ERREUR: Transmission unreachable apres 60s (auth KO ?)" >&2
  exit 1
fi

# Step 2 : POST avec le session-id et le payload de session-set
PAYLOAD="{\"method\":\"session-set\",\"arguments\":{\"peer-port\":${PORT},\"peer-port-random-on-start\":false}}"

if ! wget -q -O /dev/null \
  ${AUTH_ARG:+"$AUTH_ARG"} \
  --header="X-Transmission-Session-Id: $SID" \
  --header="Content-Type: application/json" \
  --post-data="$PAYLOAD" \
  "$RPC"; then
  echo "[update-port] ERREUR: POST session-set a echoue" >&2
  exit 1
fi

echo "[update-port] $(date -Is) Transmission peer-port -> $PORT"
