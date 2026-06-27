#!/usr/bin/env bash
# Install Vaultwarden (gestionnaire de mots de passe compatible Bitwarden).
# Mono-conteneur, base SQLite + fichiers dans /data (bind-mount DATA_DIR).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/vaultwarden/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - SIGNUPS_ALLOWED   (optionnel, defaut false)
#   - ADMIN_TOKEN       (optionnel : active le panneau /admin)
#
# Data : ${DATA_DIR} monte sur /data (db.sqlite3, attachments, sends, rsa_key*).
# MIGRATION : copier l'ancien contenu dans ${DATA_DIR}/ AVANT cet install.
# NB : les reglages sauves via le panneau /admin (config.json) priment sur les
# variables d'env (dont DOMAIN). Vaultwarden tourne en root dans le conteneur :
# il lit/ecrit les fichiers repris quel que soit leur proprietaire.

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

  # Garde-fous : vaultwarden AUTORISE les inscriptions par defaut. Si la cle
  # manque dans Infisical, l'instance serait ouverte a tous.
  for k in SIGNUPS_ALLOWED ADMIN_TOKEN SMTP_HOST SMTP_SECURITY; do
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

    build_runtime_env

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL  : https://${ADDRESS}/"
    echo "Data : ${DATA_DIR} (bind-mount sur /data ; backup auto via /home/${VPS_USER}/data/)"
    echo "Reprise : si tu migres une instance existante, copie son contenu dans"
    echo "          ${DATA_DIR}/ AVANT l'install (db.sqlite3, attachments, sends, rsa_key*)."
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
