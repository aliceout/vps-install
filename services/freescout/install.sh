#!/usr/bin/env bash
# Install FreeScout (helpdesk / boite mail partagee, PHP/Laravel + MariaDB).
# Image communautaire nfrastack/container-freescout (ex-tiredofit).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/freescout/ :
#   - ADDRESS, DOMAIN, PORT                  (PORT local proxifie par nginx, ex 8068)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DB_NAME, DB_USER, DB_PASS              (DB_PASS : openssl rand -hex 16)
#   - ADMIN_EMAIL, ADMIN_PASS               (1er compte admin, ADMIN_PASS : openssl rand -hex 12)
#   - ADMIN_FIRST_NAME, ADMIN_LAST_NAME     (optionnels, defaults Admin/User)
#   - TZ                                     (optionnel, defaut Europe/Paris)
#
# Mail : configure dans l'UI FreeScout apres install (Settings > Mail Settings
# pour le mail systeme + une Mailbox par boite). Pas de SMTP au boot.
# APP_URL est derive d'ADDRESS, APP_KEY est genere par l'image (rien a stocker).

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

build_runtime_env() {
  : "${ADDRESS:?ADDRESS manquant}"
  : "${PORT:?PORT manquant}"

  # Single Infisical : on utilise l'identite framework via infi-token (cache
  # 10min, --domain auto). Tout est sous /services/freescout/ en Cloud.
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
    echo "ADDRESS=${ADDRESS}"
    echo "DATA_DIR=${DATA_DIR}"
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

  for k in DB_NAME DB_USER DB_PASS ADMIN_EMAIL ADMIN_PASS; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent de /services/${SERVICE_NAME}/ dans Infisical Cloud."
    fi
  done
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    install -d -m 755 "$DATA_DIR"
    # mariadb:11 : entrypoint chown /var/lib/mysql au boot (run root -> drop mysql).
    install -d -m 755 "$DATA_DIR/db"
    # /data et /logs : l'image nfrastack fixe les perms internes au demarrage.
    install -d -m 755 "$DATA_DIR/data"
    install -d -m 755 "$DATA_DIR/logs"

    build_runtime_env

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL   : https://${ADDRESS}/"
    echo "Admin : ${ADMIN_EMAIL:-<ADMIN_EMAIL>} / mot de passe = ADMIN_PASS (Infisical)"
    echo "Mail  : configure Settings > Mail Settings + une Mailbox par boite dans l'UI."
    echo "Data  : ${DATA_DIR} (db + data, backup auto via /home/${VPS_USER}/data/)"
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
