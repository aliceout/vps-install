#!/usr/bin/env bash
# Install Ghost blog (image officielle ghost:5-alpine, SQLite, data sur
# disque, SMTP via Infisical self-hosted).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/choupi-blog/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted env.backlice.dev pour fetch les SMTP)
#
# Cles attendues dans Infisical SELF-HOSTED sous /choupi-blog/ (flat) :
#   - MAIL_HOST, MAIL_PORT, MAIL_USER, MAIL_PASS, MAIL_SECURE, MAIL_FROM
#
# URL est calculee a partir d'ADRESS, pas a stocker dans Infisical.

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

# Construit le runtime.env consomme par docker compose : merge des cles cloud
# (PORT, DATA_DIR, URL calculee) + des cles app fetchees depuis self-hosted
# (MAIL_*). La valeur expose juste ce dont docker-compose.yml a besoin.
build_runtime_env() {
  : "${ADRESS:?ADRESS manquant}"
  : "${PORT:?PORT manquant}"
  : "${INFISICAL_API_URL:?INFISICAL_API_URL manquant}"
  : "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID manquant}"
  : "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID manquant}"
  : "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET manquant}"
  : "${INFISICAL_ENV:?INFISICAL_ENV manquant}"

  echo "Login Infisical self-hosted (${INFISICAL_API_URL})..."
  local token
  token="$(infisical login \
    --method=universal-auth \
    --domain="$INFISICAL_API_URL" \
    --client-id="$INFISICAL_CLIENT_ID" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --plain --silent 2>/dev/null)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: login Infisical self-hosted echoue"
    exit 1
  fi

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "PORT=${PORT}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "URL=https://${ADRESS}"
    # Fetch flat /choupi-blog du self-hosted
    infisical export \
      --domain="$INFISICAL_API_URL" \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path="/${SERVICE_NAME}" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  if ! grep -q '^MAIL_HOST=' "$RUNTIME_ENV"; then
    echo "AVERTISSEMENT: MAIL_HOST absent du self-hosted. Verifie /${SERVICE_NAME}/ sur ${INFISICAL_API_URL}."
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
    echo "Setup admin : visite https://${ADRESS}/ghost/ et cree le compte owner."
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
