#!/usr/bin/env bash
# Install Miniflux (lecteur RSS Go + Postgres, data sur disque).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/miniflux/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - POSTGRES_USER, POSTGRES_PASSWORD (optionnels, defaults miniflux/<random>)
#   - POSTGRES_DB (optionnel, default miniflux)
#   - ADMIN_USERNAME, ADMIN_PASSWORD : admin cree au 1er boot (CREATE_ADMIN=1
#     idempotent, no-op si l'admin existe deja)
#   - POLLING_FREQUENCY (optionnel, minutes, default 60)

set -euo pipefail

DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME}"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical."
  exit 1
fi
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

: "${PORT:?PORT manquant dans $SECRETS_FILE}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD manquant - genere avec openssl rand -hex 16}"
: "${ADMIN_USERNAME:?ADMIN_USERNAME manquant}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD manquant - genere avec openssl rand -hex 12}"

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    # Postgres alpine run en uid 70 (pas 999 comme l'image debian officielle).
    # Bind mount doit etre owned 70:70.
    install -d -m 755 "$DATA_DIR"
    install -d -m 700 -o 70 -g 70 "$DATA_DIR/postgres"

    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE pull
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADDRESS:-?}/"
    echo "Login : ${ADMIN_USERNAME} / (mdp dans Infisical)"
    echo "Data : ${DATA_DIR}/postgres (backup auto via /home/${VPS_USER}/data/)"
    ;;

  remove)
    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE down 2>/dev/null || true
    echo "Stack arretee. Data preservee dans ${DATA_DIR} (rm -rf manuel pour purger)."
    ;;

  status)
    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE ps 2>/dev/null \
      || echo "Stack pas demarree."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
