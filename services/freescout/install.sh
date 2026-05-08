#!/usr/bin/env bash
# Install FreeScout (help desk Laravel + MariaDB linuxserver, data sur disque,
# secrets app fetchees depuis Infisical self-hosted).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/freescout/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted env.backlice.dev pour fetch les secrets app)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet freescout, racine flat :
#   - DB_ROOT_PASSWORD, DB_PASSWORD            (openssl rand -hex 16)
#   - DB_NAME, DB_USER                         (optionnels, defaults freescout)
#   - APP_KEY                                  (base64:<32B>, genere une fois :
#                                               echo "base64:$(openssl rand -base64 32)")
#   - ADMIN_EMAIL, ADMIN_PASSWORD              (admin cree au 1er boot)
#   - MAIL_HOST, MAIL_USERNAME, MAIL_PASSWORD, MAIL_FROM_ADDRESS
#   - MAIL_PORT, MAIL_ENCRYPTION, MAIL_FROM_NAME, MAIL_DRIVER  (optionnels)
#   - TIMEZONE                                 (optionnel, default Europe/Paris)
#   - PUID, PGID                               (optionnels, defaults 1000/1000)

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
# (PORT, ADDRESS, DATA_DIR, SERVICE_NAME) + dump dotenv des cles app fetchees
# depuis self-hosted (DB_*, APP_KEY, ADMIN_*, MAIL_*, TIMEZONE, PUID, PGID).
build_runtime_env() {
  : "${ADDRESS:?ADDRESS manquant}"
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
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "ADDRESS=${ADDRESS}"
    echo "DATA_DIR=${DATA_DIR}"
    # Dump tous les secrets app depuis self-hosted (projet dedie freescout,
    # racine flat).
    infisical export \
      --domain="$INFISICAL_API_URL" \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path="/" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  # Soft checks : avertit si une cle critique manque cote self-hosted.
  for k in DB_ROOT_PASSWORD DB_PASSWORD APP_KEY ADMIN_EMAIL ADMIN_PASSWORD; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent du self-hosted. Verifie /${SERVICE_NAME}/ sur ${INFISICAL_API_URL}."
    fi
  done

  # Sanity check format APP_KEY (accepte quotes simples / doubles autour
  # de la valeur : infisical export --format=dotenv wrap en "...").
  if grep -q '^APP_KEY=' "$RUNTIME_ENV" && ! grep -qE "^APP_KEY=[\"']?base64:" "$RUNTIME_ENV"; then
    echo "ERREUR: APP_KEY doit commencer par 'base64:' (Laravel format)."
    echo "        Genere une cle avec : echo \"base64:\$(openssl rand -base64 32)\""
    exit 1
  fi
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    # PUID / PGID lus depuis le runtime.env merge (defaults 1000).
    PUID="$(grep -E '^PUID=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d \"\' || true)"
    PGID="$(grep -E '^PGID=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d \"\' || true)"
    PUID="${PUID:-1000}"
    PGID="${PGID:-1000}"

    install -d -m 755 "$DATA_DIR"
    # linuxserver/mariadb chowne /config au PUID configure.
    install -d -m 700 -o "$PUID" -g "$PGID" "$DATA_DIR/db"
    # tiredofit/freescout chowne /data au PUID configure.
    install -d -m 755 -o "$PUID" -g "$PGID" "$DATA_DIR/app"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADDRESS}/"
    echo "Admin : (cf ADMIN_EMAIL / ADMIN_PASSWORD dans Infisical self-hosted)"
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
