#!/usr/bin/env bash
# Provisionne (ou met a jour) un check Healthchecks avec son planning cron
# reel, via la Management API. Sans ca, un check auto-cree par un ping
# (?create=1) herite de la periode par defaut (1 jour) -> un cron hebdo ou
# bi-quotidien apparait "en retard" (rouge) la plupart du temps alors qu'il
# tourne tres bien.
#
# Usage: hc-provision <slug> <schedule-cron> [grace-seconds]
#   Ex: hc-provision lynis-audit "45 5 * * 0" 86400
#
# - <schedule-cron> : expression cron 5-champs (min heure jour mois dow),
#                     telle que dans le crontab. Healthchecks calcule lui-meme
#                     le prochain ping attendu.
# - [grace]         : tolerance de retard en secondes (defaut 3600 = 1h).
#
# Lit HEALTHCHECKS_API_KEY + HEALTHCHECKS_API_URL depuis /etc/secrets/hc-ping.env
# (sync par l'agent Infisical). No-op silencieux si la cle ou l'URL API ne sont
# pas configurees -> safe au bootstrap initial.
#
# Le slug est prefixe par HOST_TYPE (vps/server) comme dans hc-run/hc-ping,
# pour viser le meme check que celui cree par les pings.
set -uo pipefail

slug="${1:-}"
schedule="${2:-}"
grace="${3:-3600}"

if [[ -z "$slug" || -z "$schedule" ]]; then
  echo "Usage: $(basename "$0") <slug> <schedule-cron> [grace-seconds]" >&2
  exit 64
fi

API_KEY=""
API_URL=""
TZ_VAL="Europe/Paris"
for f in /etc/secrets/hc-ping.env; do
  if [[ -s "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    API_KEY="${HEALTHCHECKS_API_KEY:-$API_KEY}"
    API_URL="${HEALTHCHECKS_API_URL:-$API_URL}"
    TZ_VAL="${HEALTHCHECKS_TZ:-$TZ_VAL}"
  fi
done

# No-op si pas de creds API (instance SaaS sans key, ou agent pas encore sync)
if [[ -z "$API_KEY" || -z "$API_URL" ]]; then
  exit 0
fi

# Prefixe le slug par HOST_TYPE pour viser le check cree par les pings
HOST_TYPE_VAL=""
if [[ -s /etc/infisical/host-type ]]; then
  HOST_TYPE_VAL="$(cat /etc/infisical/host-type)"
fi
[[ -n "$HOST_TYPE_VAL" ]] && slug="${HOST_TYPE_VAL}-${slug}"

# Normalise l'URL API (sans slash final) -> <API_URL>/checks/
API_URL="${API_URL%/}"

# unique=["name"] rend l'appel idempotent : HC cree le check s'il n'existe pas
# (par nom), sinon met a jour son schedule/tz/grace. Le nom == le slug pinge,
# car un check auto-cree via /ping/<key>/<slug> prend <slug> comme nom.
payload=$(printf '{"name":"%s","schedule":"%s","tz":"%s","grace":%s,"unique":["name"]}' \
  "$slug" "$schedule" "$TZ_VAL" "$grace")

resp_code=$(curl -fsS -m 15 --retry 2 -o /dev/null -w '%{http_code}' \
  -X POST "${API_URL}/checks/" \
  -H "X-Api-Key: ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>/dev/null || echo "000")

case "$resp_code" in
  200) echo "hc-provision: $slug mis a jour ($schedule, grace ${grace}s)" ;;
  201) echo "hc-provision: $slug cree ($schedule, grace ${grace}s)" ;;
  000) echo "hc-provision: $slug -> API injoignable (skip, non-bloquant)" >&2 ;;
  *)   echo "hc-provision: $slug -> HTTP $resp_code (skip, non-bloquant)" >&2 ;;
esac

# Jamais bloquant : un echec de provisioning ne doit pas casser un bootstrap
exit 0
