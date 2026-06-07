#!/usr/bin/env bash
# Install Watchtower (auto-update Docker containers, full coverage).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles dans Infisical CLOUD sous /services/watchtower/ (toutes optionnelles) :
#   - WATCHTOWER_SCHEDULE  (cron 6-fields, defaut "0 0 4 * * *" = 4h daily)
#   - TZ                   (defaut "Europe/Paris")

set -euo pipefail

RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME} --env-file ${RUNTIME_ENV}"

: "${VPS_USER:?VPS_USER manquant}"

build_runtime_env() {
  local token domain pid env_slug
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: infi-token KO (creds /etc/infisical/* ou connectivite ?)"
    exit 1
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id)"
  env_slug="$(cat /etc/infisical/environment)"

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    infisical export \
      --domain="$domain" \
      --projectId="$pid" \
      --env="$env_slug" \
      --path="/services/${SERVICE_NAME}" \
      --format=dotenv \
      --token="$token" 2>/dev/null || true
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    SCHEDULE_VALUE="$(grep -E '^WATCHTOWER_SCHEDULE=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"" || true)"
    echo "Schedule     : ${SCHEDULE_VALUE:-0 0 4 * * * (defaut 4h00 daily)}"
    echo "Coverage     : tous les containers (pas de filtre par label)"
    echo
    echo "Verifie que watchtower tourne :"
    echo "  docker logs ${SERVICE_NAME} 2>&1 | tail -10"
    echo
    echo "Forcer une update tout de suite (sans attendre le schedule) :"
    echo "  docker exec ${SERVICE_NAME} /watchtower --run-once"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Les containers reviendront a leur policy de tag fige (latest pull manuel via services install <nom>)."
    ;;

  status)
    cd "$SERVICE_DIR"
    $COMPOSE ps 2>/dev/null || echo "Stack pas demarree."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
