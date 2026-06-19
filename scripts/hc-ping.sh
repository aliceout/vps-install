#!/usr/bin/env bash
# Ping Healthchecks pour un check, sans executer de commande wrappee.
# Utile depuis systemd OnSuccess=/OnFailure= (template units hc-ping@) ou
# pour un ping manuel ponctuel.
#
# Usage: hc-ping <slug> [ok|fail|start]
#
# Le slug est prefixe par HOST_TYPE (vps/server) comme dans hc-run, pour
# distinguer les checks d'un host a l'autre dans Healthchecks.
set -uo pipefail

slug="${1:-}"
status="${2:-ok}"

if [[ -z "$slug" ]]; then
  echo "Usage: $(basename "$0") <slug> [ok|fail|start]" >&2
  exit 64
fi

PING_KEY=""
URL_BASE="https://hc-ping.com"
for f in /etc/secrets/healthchecks.env /etc/secrets/hc-ping.env; do
  if [[ -s "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    PING_KEY="${HEALTHCHECKS_PING_KEY:-$PING_KEY}"
    URL_BASE="${HEALTHCHECKS_URL_BASE:-$URL_BASE}"
  fi
done

HOST_TYPE_VAL=""
if [[ -s /etc/infisical/host-type ]]; then
  HOST_TYPE_VAL="$(cat /etc/infisical/host-type)"
fi
[[ -n "$HOST_TYPE_VAL" ]] && slug="${HOST_TYPE_VAL}-${slug}"

# No-op si pas de cle (bootstrap initial, ou Infisical en panne)
[[ -z "$PING_KEY" ]] && exit 0

case "$status" in
  ok)    suffix="" ;;
  fail)  suffix="/fail" ;;
  start) suffix="/start" ;;
  *)     suffix="/${status}" ;;
esac

# Ping robuste + observable : retries agressifs et, en cas d'echec definitif,
# trace dans /var/log/hc-ping.log (sans la cle de ping). Voir hc-run.sh.
rc=0
curl -fsS -m 10 --retry 5 --retry-delay 2 --retry-all-errors -o /dev/null \
  "${URL_BASE}/${PING_KEY}/${slug}${suffix}?create=1" 2>/dev/null || rc=$?
if (( rc != 0 )); then
  printf '%s hc-ping slug=%s stage=%s base=%s curl_rc=%s\n' \
    "$(date -Is)" "$slug" "$status" "$URL_BASE" "$rc" \
    >> /var/log/hc-ping.log 2>/dev/null || true
fi
