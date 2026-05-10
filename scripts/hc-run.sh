#!/usr/bin/env bash
# Wrap une commande cron avec un ping Healthchecks (start + result).
# Usage: hc-run <slug> <command> [args...]
#
# Lit HEALTHCHECKS_PING_KEY depuis /etc/secrets/healthchecks.env (sync via
# Infisical agent depuis /infra/shared/HEALTHCHECKS_PING_KEY).
#
# Si la cle est absente (Infisical pas encore configure, secret pas defini),
# le wrapper exec direct la commande sans pinger -> safe pour le bootstrap
# initial et pour debugger sans bloquer les crons.
#
# Le slug est prefixe par HOST_TYPE (vps/server) pour distinguer les checks
# d'un host a l'autre dans Healthchecks. Auto-provisioning recommande cote
# Healthchecks (Project Settings) pour creer les checks au premier ping.
set -uo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <slug> <command> [args...]" >&2
  exit 64
fi

slug="$1"; shift

# Charge la cle Healthchecks depuis le fichier sync par l'agent Infisical
PING_KEY=""
if [[ -s /etc/secrets/healthchecks.env ]]; then
  # shellcheck disable=SC1091
  source /etc/secrets/healthchecks.env
  PING_KEY="${HEALTHCHECKS_PING_KEY:-}"
fi

# Prefixe le slug par HOST_TYPE pour distinguer les checks vps/server
HOST_TYPE_VAL=""
if [[ -s /etc/infisical/host-type ]]; then
  HOST_TYPE_VAL="$(cat /etc/infisical/host-type)"
fi
[[ -n "$HOST_TYPE_VAL" ]] && slug="${HOST_TYPE_VAL}-${slug}"

# No-op si pas de cle (bootstrap initial, ou Infisical en panne)
if [[ -z "$PING_KEY" ]]; then
  exec "$@"
fi

url="https://hc-ping.com/${PING_KEY}/${slug}"

# ?create=1 : auto-cree le check au premier ping s'il n'existe pas encore
# (sinon Healthchecks renvoie 404 sur slug inconnu).
curl -fsS -m 10 --retry 3 -o /dev/null "${url}/start?create=1" 2>/dev/null || true

"$@"
rc=$?

# Ping resultat avec exit code (0 = OK, autre = fail)
curl -fsS -m 10 --retry 3 -o /dev/null "${url}/${rc}?create=1" 2>/dev/null || true

exit "$rc"
