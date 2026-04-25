#!/usr/bin/env bash
# Webhook hook 2mains. Refetch les secrets self-hosted (rotation transparente),
# regenere /var/lib/services/2mains/runtime.env, pull + up.
set -Eeuo pipefail

SERVICE_NAME="2mains"
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
COMPOSE_DIR="/opt/vps-install/services/${SERVICE_NAME}"

# shellcheck disable=SC1091
source "/etc/secrets/${SERVICE_NAME}.env"

: "${ADRESS:?ADRESS manquant}"
: "${PORT_SITE:?PORT_SITE manquant}"
: "${PORT_MAIL:?PORT_MAIL manquant}"
: "${INFISICAL_API_URL:?INFISICAL_API_URL manquant}"
: "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID manquant}"
: "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID manquant}"
: "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET manquant}"
: "${INFISICAL_ENV:?INFISICAL_ENV manquant}"

TOKEN="$(infisical login \
  --method=universal-auth \
  --domain="$INFISICAL_API_URL" \
  --client-id="$INFISICAL_CLIENT_ID" \
  --client-secret="$INFISICAL_CLIENT_SECRET" \
  --plain --silent 2>/dev/null)"
[[ -n "$TOKEN" ]] || { echo "ERR: login Infisical echoue"; exit 1; }

umask 077
{
  echo "SERVICE_NAME=${SERVICE_NAME}"
  echo "PORT_SITE=${PORT_SITE}"
  echo "PORT_MAIL=${PORT_MAIL}"
  infisical export \
    --domain="$INFISICAL_API_URL" \
    --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --path="/" \
    --format=dotenv \
    --token="$TOKEN"
} > "$RUNTIME_ENV"
chmod 640 "$RUNTIME_ENV" 2>/dev/null || true

cd "$COMPOSE_DIR"
docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" pull
docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" up -d

echo "[$(date -Iseconds)] ${SERVICE_NAME} deploye (images GHCR latest)"
