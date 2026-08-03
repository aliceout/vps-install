#!/usr/bin/env bash
# Install Dolibarr (ERP/CRM, PHP + MariaDB). Image officielle dolibarr/dolibarr.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/dolibarr/ :
#   - ADDRESS, DOMAIN, PORT                  (PORT local proxifie par nginx, ex 8069)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DB_DATABASE, DB_USERNAME, DB_PASSWORD  (DB_PASSWORD : openssl rand -hex 16)
#   - ADMIN_PASSWORD                          (mot de passe du 1er admin)
#   - INSTANCE_UNIQUE_ID                      (STABLE : openssl rand -hex 16 ; ne
#                                              JAMAIS le changer apres le 1er install)
#   - ADMIN_LOGIN                             (optionnel, defaut admin)
#   - IMAGE_TAG                               (optionnel, defaut latest ; pinne une
#                                              version pour un deploy reproductible)
#   - TZ                                      (optionnel, defaut Europe/Paris)

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
  # 10min, --domain auto). Tout est sous /services/dolibarr/ en Cloud.
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

  for k in DB_DATABASE DB_USERNAME DB_PASSWORD ADMIN_PASSWORD INSTANCE_UNIQUE_ID; do
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
    # documents/ + custom/ : l'image dolibarr fixe les perms (www-data) au boot.
    install -d -m 755 "$DATA_DIR/documents"
    install -d -m 755 "$DATA_DIR/custom"

    build_runtime_env

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL   : https://${ADDRESS}/"
    echo "Admin : ${ADMIN_LOGIN:-admin} / mot de passe = ADMIN_PASSWORD (Infisical)"
    echo "Data  : ${DATA_DIR} (db + documents + custom, backup auto via /home/${VPS_USER}/data/)"
    echo "Note  : 1er boot = install auto (peut prendre ~1min). Suis 'docker logs -f ${SERVICE_NAME}'."
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
