#!/usr/bin/env bash
# Install Immich (gestionnaire photos self-hosted, 4 containers).
# Service home server uniquement.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/immich/ :
#   - ADDRESS, DOMAIN, PORT       (PORT host expose par le container server)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - LIBRARY_PATH                (ex: /media/pi/data/cloud/Photos, bibliotheque
#                                  externe deja organisee, mountee RW dans /library)
#   - DB_PASSWORD                 (genere une fois, openssl rand -hex 32)
#   - IMMICH_VERSION              (optionnel, defaut "release")
#   - TZ                          (optionnel, defaut "Europe/Paris")
#
# DATA_DIR (uploads + ML cache + postgres) est auto-cale sur
# /home/$VPS_USER/data/immich, comme les autres services framework
# (fider/garden-blog/etc.). Pas configurable via Infisical, c'est de
# l'ops data, pas du media.

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
  # 10min, --domain auto). Tout est sous /services/immich/ en Cloud.
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

  # UID/GID host pour que server + ML tournent comme VPS_USER (= les fichiers
  # crees dans /library et /usr/src/app/upload appartiennent au user host).
  local host_uid host_gid
  host_uid="$(id -u "$VPS_USER")"
  host_gid="$(id -g "$VPS_USER")"

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

  for k in LIBRARY_PATH DB_PASSWORD; do
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

    LIBRARY_PATH_VALUE="$(grep -E '^LIBRARY_PATH=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$LIBRARY_PATH_VALUE" ]]; then
      echo "ERREUR: LIBRARY_PATH vide dans le runtime.env. Set-le sous /services/${SERVICE_NAME}/ en Infisical Cloud."
      exit 1
    fi

    # Cree les sous-dossiers DATA_DIR (uploads + ML cache + postgres).
    # DATA_DIR vit dans /home/$VPS_USER/data/immich, auto-cale.
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR"
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR/upload"
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR/model-cache"
    # Postgres image officielle (immich) tourne en UID 999
    install -d -m 700 -o 999 -g 999 "$DATA_DIR/postgres"

    if [[ ! -d "$LIBRARY_PATH_VALUE" ]]; then
      echo "ERREUR: $LIBRARY_PATH_VALUE n'existe pas. Cree-le ou pointe LIBRARY_PATH ailleurs."
      echo "  Si c'est ton dossier photos perso, verifie qu'il est bien monte/accessible."
      exit 1
    fi

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL  : https://${ADDRESS}/"
    echo "Data : ${DATA_DIR} (uploads + ML cache + postgres)"
    echo "Lib  : ${LIBRARY_PATH_VALUE} (bibliotheque externe, RW)"
    echo
    echo "Premier setup :"
    echo "  1. Visite https://${ADDRESS}/ → cree le compte admin"
    echo "  2. Settings → External Libraries → New Library → path /library"
    echo "  3. (Optionnel) Active 'auto-album from path' pour creer tes albums"
    echo "     a partir de tes dossiers."
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans DATA_DIR + LIBRARY_PATH (rm -rf manuel pour purger)."
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
