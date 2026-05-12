#!/usr/bin/env bash
# infi-token : wrapper sur 'infisical login' qui :
#   - lit l'adresse Infisical depuis /etc/infisical/address (fallback parsing
#     agent.base.yaml ou app.infisical.com) -> resout le bug ou les scripts
#     legacy se logaient implicitement sur app.infisical.com meme avec un
#     Infisical self-hosted
#   - cache le token dans /run/infi-token/token (chmod 600 root) avec TTL 10min
#     -> evite de marteler Infisical (rate-limit ~60 req/min) quand plusieurs
#     scripts cron + services s'authentifient en parallele
#
# Usage:
#   TOKEN="$(infi-token)"
#   infisical secrets get FOO \
#     --domain="$(infi-token --domain)" --token="$TOKEN" \
#     --projectId=... --env=... --path=...
#
# Options:
#   --domain   : print juste l'adresse Infisical persistee (utile pour ajouter
#                --domain="..." aux 'infisical secrets ...' downstream)
#   --refresh  : force re-login meme si le cache est encore valide
#   --silent   : suppress les warnings sur stderr (pour cron)

set -euo pipefail

CACHE_DIR="/run/infi-token"
CACHE_FILE="$CACHE_DIR/token"
CACHE_TTL=600

ADDR_FILE="/etc/infisical/address"
CLIENT_ID_FILE="/etc/infisical/client-id"
CLIENT_SECRET_FILE="/etc/infisical/client-secret"
AGENT_BASE="/etc/infisical/agent.base.yaml"

REFRESH=0
SILENT=0
DOMAIN_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --refresh) REFRESH=1 ;;
    --silent)  SILENT=1 ;;
    --domain)  DOMAIN_ONLY=1 ;;
    -h|--help)
      sed -n '/^# infi-token/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "infi-token: option inconnue: $arg" >&2
      exit 2
      ;;
  esac
done

warn() { (( SILENT == 1 )) || echo "infi-token: $*" >&2; }

# Resolution de l'adresse Infisical :
# 1) /etc/infisical/address (persiste par modules/35_infisical.sh)
# 2) parsing de agent.base.yaml (migration: vieilles installs sans address)
# 3) https://app.infisical.com (fallback SaaS)
ADDR=""
if [[ -s "$ADDR_FILE" ]]; then
  ADDR="$(cat "$ADDR_FILE")"
fi
if [[ -z "$ADDR" && -s "$AGENT_BASE" ]]; then
  ADDR="$(awk '/^[[:space:]]*address:/ { print $2; exit }' "$AGENT_BASE" 2>/dev/null || true)"
fi
ADDR="${ADDR:-https://app.infisical.com}"

if (( DOMAIN_ONLY == 1 )); then
  printf '%s\n' "$ADDR"
  exit 0
fi

if [[ ! -s "$CLIENT_ID_FILE" || ! -s "$CLIENT_SECRET_FILE" ]]; then
  warn "client-id ou client-secret manquant dans /etc/infisical/"
  exit 1
fi

# Cache hit : pas --refresh ET fichier present ET age < TTL
if (( REFRESH == 0 )) && [[ -s "$CACHE_FILE" ]]; then
  cache_mtime="$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  age=$(( now - cache_mtime ))
  if (( age < CACHE_TTL )); then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

install -d -m 700 "$CACHE_DIR"

CID="$(cat "$CLIENT_ID_FILE")"
CSEC="$(cat "$CLIENT_SECRET_FILE")"

TOKEN="$(
  infisical login \
    --method=universal-auth \
    --domain="$ADDR" \
    --client-id="$CID" \
    --client-secret="$CSEC" \
    --plain --silent 2>/dev/null || true
)"

if [[ -z "$TOKEN" ]]; then
  warn "login Infisical echoue (verifie creds et connectivite vers $ADDR)"
  exit 1
fi

umask 077
printf '%s' "$TOKEN" > "$CACHE_FILE"
chmod 600 "$CACHE_FILE"
printf '%s\n' "$TOKEN"
