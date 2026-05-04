#!/usr/bin/env bash
# Install Quackback (feedback platform open-source, alternative Canny).
# Stack : Postgres (custom + pg_cron) + Dragonfly + App (build local depuis source).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/quackback/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted env.backlice.dev pour fetch les secrets app)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet quackback, racine flat :
#   - POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#   - REDIS_PASSWORD                  (openssl rand -hex 16)
#   - SECRET_KEY                      (openssl rand -base64 32, MIN 32 chars)
#   - EMAIL_SMTP_HOST, EMAIL_SMTP_USER, EMAIL_SMTP_PASS, EMAIL_FROM
#   - EMAIL_SMTP_PORT, EMAIL_SMTP_SECURE  (optionnels)

set -euo pipefail

DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
SOURCE_DIR="${RUNTIME_DIR}/src"
SOURCE_REPO="https://github.com/QuackbackIO/quackback.git"
SOURCE_BRANCH="main"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME} --env-file ${RUNTIME_ENV}"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

# Sync du source repo (Quackback ne publie pas d'image, on build local).
sync_source() {
  install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$RUNTIME_DIR"
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    runuser -u "$VPS_USER" -- git -C "$SOURCE_DIR" fetch --all --prune
    runuser -u "$VPS_USER" -- git -C "$SOURCE_DIR" checkout "$SOURCE_BRANCH"
    runuser -u "$VPS_USER" -- git -C "$SOURCE_DIR" reset --hard "origin/${SOURCE_BRANCH}"
  else
    runuser -u "$VPS_USER" -- git clone --branch "$SOURCE_BRANCH" "$SOURCE_REPO" "$SOURCE_DIR"
  fi
}

# Construit le runtime.env consomme par docker compose : merge cloud
# (PORT, ADRESS, computed) + dump dotenv self-hosted (POSTGRES_*, REDIS_*,
# SECRET_KEY, EMAIL_*).
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
    echo "ADRESS=${ADRESS}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "SOURCE_DIR=${SOURCE_DIR}"
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

  for k in POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB REDIS_PASSWORD SECRET_KEY; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent du self-hosted. Verifie /quackback/ sur ${INFISICAL_API_URL}."
    fi
  done
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    install -d -m 755 "$DATA_DIR"
    # postgres:18 run en uid 999 (postgres user, defini par le base image officiel).
    install -d -m 700 -o 999 -g 999 "$DATA_DIR/postgres"
    # Dragonfly run en uid 65533 (nobody) par defaut, mais accepte n'importe
    # quel uid si /data est ecrivable. On laisse 755 ouvert.
    install -d -m 755 "$DATA_DIR/dragonfly"

    sync_source
    build_runtime_env

    cd "$SERVICE_DIR"
    echo "Build des images locales (postgres custom + app, peut prendre 5-10 min au 1er run)..."
    $COMPOSE build
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADRESS}/"
    echo "Setup admin : visite l'URL et signup avec le 1er compte (= admin)."
    echo "Source : ${SOURCE_DIR}"
    echo "Data   : ${DATA_DIR}/{postgres,dragonfly} (backup auto via /home/${VPS_USER}/data/)"
    echo
    echo "1er boot : ~30-60s pour migrations DB + warmup."
    echo "  docker logs -f ${SERVICE_NAME}     pour suivre."
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans ${DATA_DIR} (rm -rf manuel pour purger)."
    echo "Source preserve dans ${SOURCE_DIR} (rm -rf manuel pour purger)."
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
