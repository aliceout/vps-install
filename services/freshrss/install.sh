#!/usr/bin/env bash
# Install FreshRSS (image officielle, SQLite, data sur disque host).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/freshrss/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - TZ            (optionnel, default Europe/Paris)
#   - CRON_MIN      (optionnel, default "*/20" - refresh feeds toutes les 20 min)
#
# Pas de secrets app : l'admin se cree au premier acces via l'UI web.

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

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    # FreshRSS run en www-data (uid 33) dans le container.
    # Le bind mount doit etre owned 33:33 pour que le container puisse ecrire.
    install -d -m 755 -o 33 -g 33 "$DATA_DIR"
    install -d -m 755 -o 33 -g 33 "$DATA_DIR/data"
    install -d -m 755 -o 33 -g 33 "$DATA_DIR/extensions"

    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE pull
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADRESS:-?}/"
    echo "Setup admin : visite l'URL et complete le wizard de premier lancement."
    echo "Data : ${DATA_DIR}/data (backup auto via /home/${VPS_USER}/data/)"
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
