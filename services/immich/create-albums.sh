#!/usr/bin/env bash
# Cree des albums Immich a partir de la structure de dossiers de la library
# externe (EXTERNAL_LIBRARY = dossier photos Nextcloud).
#
# Wrappe l'image https://github.com/Salvoxia/immich-folder-album-creator.
# Le tool lit les assets DEJA indexes par Immich (via API REST) et cree des
# albums en les referencant. Pas de copie, pas d'upload, juste de la metadata.
# Idempotent : re-run = no-op si les albums existent deja.
#
# Variables lues depuis /var/lib/services/immich/runtime.env :
#   - SERVICE_NAME       (pour resoudre le network compose + le container)
#   - IMMICH_API_KEY     (obligatoire, genere depuis l'UI Immich)
#   - ALBUM_LEVELS       (optionnel, defaut 1)
#   - ALBUM_SEPARATOR    (optionnel, defaut " / ")
#   - ALBUM_ROOT_PATH    (optionnel, defaut /library = mount external library)
#   - ALBUM_PATH_FILTER  (optionnel, glob fnmatch matche au path relatif a
#                        ROOT_PATH. Seuls les assets matchant sont inclus.
#                        Ex: "*/*" pour limiter aux photos directement dans
#                        un dossier de premier niveau (ignore les photos
#                        plus profondes).

set -Eeuo pipefail

RUNTIME_ENV="/var/lib/services/immich/runtime.env"
if [[ ! -f "$RUNTIME_ENV" ]]; then
  echo "ERREUR: $RUNTIME_ENV absent (immich pas installe ?)" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$RUNTIME_ENV"

: "${SERVICE_NAME:?ERREUR: SERVICE_NAME manquant dans $RUNTIME_ENV}"
: "${IMMICH_API_KEY:?ERREUR: IMMICH_API_KEY non set dans Infisical /services/immich/}"

ALBUM_LEVELS="${ALBUM_LEVELS:-1}"
ALBUM_SEPARATOR="${ALBUM_SEPARATOR:- / }"
ALBUM_ROOT_PATH="${ALBUM_ROOT_PATH:-/library}"

# On joint le network compose immich pour resoudre "${SERVICE_NAME}-server"
# en DNS interne (= container_name immich-server, qui ecoute sur 2283).
NETWORK="${SERVICE_NAME}_default"
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "ERREUR: network $NETWORK absent (stack immich pas demarree ?)" >&2
  exit 1
fi

echo "[$(date -Is)] album-create: levels=$ALBUM_LEVELS root=$ALBUM_ROOT_PATH filter=${ALBUM_PATH_FILTER:-<none>}"

# PATH_FILTER en variable optionnelle : on ne passe -e PATH_FILTER que si
# ALBUM_PATH_FILTER est set + non-vide (sinon le tool interprete une chaine
# vide comme un filtre qui exclut tout).
DOCKER_FILTER_ARG=()
if [[ -n "${ALBUM_PATH_FILTER:-}" ]]; then
  DOCKER_FILTER_ARG=(-e "PATH_FILTER=$ALBUM_PATH_FILTER")
fi

docker run --rm \
  --network "$NETWORK" \
  -e API_URL="http://${SERVICE_NAME}-server:2283/api/" \
  -e API_KEY="$IMMICH_API_KEY" \
  -e ROOT_PATH="$ALBUM_ROOT_PATH" \
  -e ALBUM_LEVELS="$ALBUM_LEVELS" \
  -e ALBUM_SEPARATOR="$ALBUM_SEPARATOR" \
  "${DOCKER_FILTER_ARG[@]}" \
  -e UNATTENDED=1 \
  -e LOG_LEVEL=INFO \
  salvoxia/immich-folder-album-creator:latest

echo "[$(date -Is)] album-create: termine"
