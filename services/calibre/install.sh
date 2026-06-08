#!/usr/bin/env bash
# Install Calibre Web (lscr.io/linuxserver/calibre-web).
# Home server uniquement (en principe : la bibliotheque vit la-bas).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/calibre/ :
#   - ADDRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DATA_PATH                   chemin host de la bibliotheque Calibre
#                                 existante (ex: /media/pi/media/books).
#                                 Doit contenir un metadata.db.
#   - TZ                          (optionnel, defaut "Europe/Paris")
#
# DATA_DIR (config calibre-web) auto-cale sur /home/$VPS_USER/data/calibre,
# pattern framework standard (cf syncthing, torrent).
#
# Auth : Calibre Web a son propre systeme (admin/admin123 par defaut, a
# changer au 1er login). Pas de tinyauth en front.

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

  local token domain pid env_slug host_uid host_gid
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: infi-token KO (creds /etc/infisical/* ou connectivite ?)"
    exit 1
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id)"
  env_slug="$(cat /etc/infisical/environment)"

  host_uid="$(id -u "$VPS_USER")"
  host_gid="$(id -g "$VPS_USER")"

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "ADDRESS=${ADDRESS}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "HOST_UID=${host_uid}"
    echo "HOST_GID=${host_gid}"
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

  if ! grep -q "^DATA_PATH=" "$RUNTIME_ENV"; then
    echo "AVERTISSEMENT: DATA_PATH absent de /services/${SERVICE_NAME}/ dans Infisical Cloud."
  fi
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    DATA_PATH_VALUE="$(grep -E '^DATA_PATH=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$DATA_PATH_VALUE" ]]; then
      echo "ERREUR: DATA_PATH vide dans le runtime.env. Set-le sous /services/${SERVICE_NAME}/ en Infisical Cloud."
      echo "  Ex: /media/pi/media/books"
      exit 1
    fi
    if [[ ! -d "$DATA_PATH_VALUE" ]]; then
      echo "ERREUR: $DATA_PATH_VALUE n'existe pas. Cree-le ou corrige DATA_PATH dans Infisical."
      exit 1
    fi
    if [[ ! -f "$DATA_PATH_VALUE/metadata.db" ]]; then
      echo "AVERTISSEMENT: $DATA_PATH_VALUE/metadata.db absent. Calibre Web te proposera"
      echo "  d'initialiser une lib vide au premier login (Admin -> 'Edit Books' -> set"
      echo "  Calibre Library location)."
    fi

    HOST_UID_VALUE="$(id -u "$VPS_USER")"
    HOST_GID_VALUE="$(id -g "$VPS_USER")"

    # DATA_DIR : config + state calibre-web, owned par VPS_USER.
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_DIR" \
      "$DATA_DIR/config"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/"
    echo "Ops data     : ${DATA_DIR}/config (app.db calibre-web)"
    echo "Books        : ${DATA_PATH_VALUE} (mount /books dans le container)"
    echo
    echo "Premier setup :"
    echo "  1. Connecte-toi : user=admin, pass=admin123 (a CHANGER tout de suite"
    echo "     dans Admin -> Edit Users)"
    echo "  2. Si Calibre Web demande la location de la bibliotheque,"
    echo "     mets : /books"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Config + livres preserves dans DATA_DIR / DATA_PATH."
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
