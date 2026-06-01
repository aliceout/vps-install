#!/usr/bin/env bash
# Webhook hook pour Blog. Appele par le webhooks receiver sur
# workflow_run <WORKFLOW> success.
#
# Pas de git pull, pas de build : l'image est buildee par GitHub Actions
# et publiee sur GHCR (tag latest mouvant). On fait juste pull + up qui
# recupere la nouvelle image et recrée le container.
set -Eeuo pipefail

# Source PORT + IMAGE + CONTAINER_PORT depuis l'env file synce par
# Infisical agent.
# shellcheck disable=SC1091
source /etc/secrets/blog.env

: "${PORT:?PORT manquant dans /etc/secrets/blog.env}"
: "${IMAGE:?IMAGE manquant dans /etc/secrets/blog.env}"
: "${CONTAINER_PORT:?CONTAINER_PORT manquant dans /etc/secrets/blog.env}"

COMPOSE_DIR="/opt/vps-install/services/blog"
cd "$COMPOSE_DIR"

HOST_PORT="$PORT" CONTAINER_PORT="$CONTAINER_PORT" IMAGE="$IMAGE" \
  SERVICE_NAME="blog" docker compose -p blog pull
HOST_PORT="$PORT" CONTAINER_PORT="$CONTAINER_PORT" IMAGE="$IMAGE" \
  SERVICE_NAME="blog" docker compose -p blog up -d

echo "[$(date -Iseconds)] blog deploye (image GHCR latest)"
