#!/usr/bin/env bash
# Install Jellyfin (media server, lscr.io/linuxserver/jellyfin).
# Service home server uniquement.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/jellyfin/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet jellyfin, racine flat :
#   - CONFIG_DIR    (ex: /media/pi/media/config)
#   - MEDIA_ROOT    (ex: /media/pi/media/transmission/completed)
#
# Auth : geree par Jellyfin lui-meme (comptes utilisateurs internes).
# Pas de tinyauth en front (contrairement a torrent).

set -euo pipefail

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
    --plain </dev/null 2>/dev/null)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: login Infisical self-hosted echoue"
    exit 1
  fi

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "ADRESS=${ADRESS}"
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

  for k in CONFIG_DIR MEDIA_ROOT; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent du self-hosted. Verifie /${SERVICE_NAME}/ sur ${INFISICAL_API_URL}."
    fi
  done
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    CONFIG_VALUE="$(grep -E '^CONFIG_DIR=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    MEDIA_VALUE="$(grep -E '^MEDIA_ROOT=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$CONFIG_VALUE" || -z "$MEDIA_VALUE" ]]; then
      echo "ERREUR: CONFIG_DIR ou MEDIA_ROOT vide dans le runtime.env."
      exit 1
    fi
    if [[ ! -d "$CONFIG_VALUE" ]]; then
      echo "AVERTISSEMENT: $CONFIG_VALUE n'existe pas. Cree-le :"
      echo "  sudo install -d -m 755 -o $VPS_USER -g $VPS_USER '$CONFIG_VALUE'"
      exit 1
    fi
    if [[ ! -d "$MEDIA_VALUE" ]]; then
      echo "AVERTISSEMENT: $MEDIA_VALUE n'existe pas. Verifie le path."
      exit 1
    fi

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADRESS}/"
    echo "Auth : login Jellyfin interne (1er user cree au setup wizard)"
    echo "Config : ${CONFIG_VALUE}"
    echo "Media  : ${MEDIA_VALUE}/{series,films/1900,films/2000,docs,series-docs,anims,eros}"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Config + media preserves dans CONFIG_DIR / MEDIA_ROOT."
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
