#!/usr/bin/env bash
# Install FreeScout (help desk Laravel + MariaDB, image tiredofit, data sur disque).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical sous /services/freescout/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DB_ROOT_PASSWORD             (openssl rand -hex 16)
#   - DB_PASSWORD                  (openssl rand -hex 16)
#   - DB_NAME, DB_USER             (optionnels, defaults freescout/freescout)
#   - APP_KEY                      ("base64:" + 32 bytes en base64,
#                                   genere une fois avec :
#                                   echo "base64:$(openssl rand -base64 32)")
#   - ADMIN_EMAIL, ADMIN_PASSWORD  (admin cree au 1er boot, idempotent)
#   - TIMEZONE                     (optionnel, default Europe/Paris)
#   - MAIL_HOST, MAIL_USERNAME, MAIL_PASSWORD, MAIL_FROM_ADDRESS
#     (+ optionnels MAIL_PORT, MAIL_ENCRYPTION, MAIL_FROM_NAME, MAIL_DRIVER)
#   - PUID, PGID                   (optionnels, defaults 1000/1000)

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
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD manquant - genere avec openssl rand -hex 16}"
: "${DB_PASSWORD:?DB_PASSWORD manquant - genere avec openssl rand -hex 16}"
: "${APP_KEY:?APP_KEY manquant - genere avec : echo \"base64:\$(openssl rand -base64 32)\"}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL manquant}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD manquant - genere avec openssl rand -hex 12}"

# Sanity check format APP_KEY
if [[ "$APP_KEY" != base64:* ]]; then
  echo "ERREUR: APP_KEY doit commencer par 'base64:' (Laravel format)."
  echo "        Genere une cle avec : echo \"base64:\$(openssl rand -base64 32)\""
  exit 1
fi

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    install -d -m 755 "$DATA_DIR"
    # MariaDB run en uid 999 (mariadb user dans l'image officielle).
    install -d -m 700 -o 999 -g 999 "$DATA_DIR/db"
    # tiredofit/freescout chowne /data au PUID configure (default 1000).
    install -d -m 755 -o "$PUID" -g "$PGID" "$DATA_DIR/app"

    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE pull
    SERVICE_NAME="$SERVICE_NAME" DATA_DIR="$DATA_DIR" $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADRESS:-?}/"
    echo "Admin : ${ADMIN_EMAIL} / (mdp dans Infisical)"
    echo "Data : ${DATA_DIR}/{db,app} (backup auto via /home/${VPS_USER}/data/)"
    echo
    echo "1er boot : compte ~30-60s d'init (Laravel migrations + seed admin)."
    echo "  docker logs -f ${SERVICE_NAME}     pour suivre."
    echo
    echo "Config IMAP/POP3 des mailboxes : a faire dans l'UI une fois logge"
    echo "  (Manage -> Mailboxes -> Connection Settings)."
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
