#!/usr/bin/env bash
# Install Ghost blog (image officielle ghost:5-alpine, SQLite, data sur disque).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/garden-blog/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_PASS, MAIL_SECURE, MAIL_FROM
#
# URL est calculee a partir d'ADDRESS, pas a stocker dans Infisical.

set -euo pipefail

DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME} --env-file ${RUNTIME_ENV}"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# Construit le runtime.env consomme par docker compose : merge des cles
# "framework" (PORT, DATA_DIR, URL calculee) + export de toutes les cles sous
# /services/garden-blog/ Cloud (ADDRESS, DOMAIN, MAIL_*, etc.).
build_runtime_env() {
  : "${ADDRESS:?ADDRESS manquant}"
  : "${PORT:?PORT manquant}"

  # Single Infisical : on utilise l'identite framework via infi-token (cache
  # 10min, --domain auto). Tout est sous /services/garden-blog/ en Cloud.
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
    echo "PORT=${PORT}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "URL=https://${ADDRESS}"
    infisical export \
      --domain="$domain" \
      --projectId="$pid" \
      --env="$env_slug" \
      --path="/services/${SERVICE_NAME}" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  if ! grep -q '^MAIL_HOST=' "$RUNTIME_ENV"; then
    echo "AVERTISSEMENT: MAIL_HOST absent de /services/${SERVICE_NAME}/ dans Infisical Cloud."
  fi
}

case "$ACTION" in
  install|update)
    # Data dir : owner uid/gid 1000 = user 'node' a l'interieur du container
    # Ghost officiel. Fonctionne aussi si VPS_USER est lui-meme uid 1000.
    install -d -m 755 -o 1000 -g 1000 "$DATA_DIR"
    install -d -m 755 -o 1000 -g 1000 "$DATA_DIR/content"

    build_runtime_env

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "Setup admin : visite https://${ADDRESS}/ghost/ et cree le compte owner."
    echo "Data : ${DATA_DIR}/content (backup auto via /home/${VPS_USER}/data/)"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans ${DATA_DIR} (rm -rf manuel pour purger)."
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
