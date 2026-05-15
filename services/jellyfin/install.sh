#!/usr/bin/env bash
# Install Jellyfin (media server, lscr.io/linuxserver/jellyfin).
# Service home server uniquement.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/jellyfin/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
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
  : "${ADDRESS:?ADDRESS manquant}"
  : "${PORT:?PORT manquant}"

  # Single Infisical : on utilise l'identite framework via infi-token (cache
  # 10min, --domain auto). Tout est sous /services/jellyfin/ en Cloud.
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

  for k in CONFIG_DIR MEDIA_ROOT; do
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
    echo "URL : https://${ADDRESS}/"
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
