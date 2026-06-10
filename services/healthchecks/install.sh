#!/usr/bin/env bash
# Install Healthchecks.io self-hosted (monitoring crons).
# Service VPS uniquement par convention (pas server, pour eviter qu'un crash
# du home server fasse perdre les alertes du VPS).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/healthchecks/ :
#   - ADDRESS, DOMAIN, PORT          (port host, bind localhost)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - SECRET_KEY                     (Django, genere via openssl rand -hex 64)
#   - SUPERUSER_EMAIL                (admin login email)
#   - SUPERUSER_PASSWORD             (admin login password)
#   - SITE_NAME                      (optionnel, defaut "Healthchecks")
#   - SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_USE_TLS  (optionnels)

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

  for k in SECRET_KEY SUPERUSER_EMAIL SUPERUSER_PASSWORD; do
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

    build_runtime_env

    HOST_UID_VALUE="$(id -u "$VPS_USER")"
    HOST_GID_VALUE="$(id -g "$VPS_USER")"

    # DATA_DIR : SQLite DB + media uploads (badges). Owned VPS_USER.
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_DIR" \
      "$DATA_DIR/data"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/"
    echo "Ops data     : ${DATA_DIR}/data (SQLite DB + media)"
    echo
    echo "Premier login :"
    echo "  1. Visite https://${ADDRESS}/accounts/login/"
    echo "  2. user/pass = SUPERUSER_EMAIL / SUPERUSER_PASSWORD (Infisical)"
    echo "  3. Cree un projet (ex: 'VPS' ou 'Server'), recupere son ping_key"
    echo "  4. Mets-le dans Infisical /infra/<host_type>/HEALTHCHECKS_PING_KEY"
    echo
    echo "Puis sur chaque host (vps + home server) :"
    echo "  - Set HEALTHCHECKS_URL_BASE=https://${ADDRESS}/ping dans Infisical"
    echo "    /infra/shared/ pour rediriger les pings vers ton instance"
    echo "  - infisical-agent picke la nouvelle config au prochain poll (5min)"
    echo "  - Les hc-run construiront URL = \$HEALTHCHECKS_URL_BASE/\$PING_KEY/\$slug"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans ${DATA_DIR}/data (rm -rf manuel pour purger)."
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
