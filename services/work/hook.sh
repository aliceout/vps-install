#!/usr/bin/env bash
# Webhook hook pour Work-resume. Appele par le webhooks receiver sur
# workflow_run "Docker build" success.
#
# Pas de git pull, pas de build : l'image est buildee par GitHub Actions
# et publiee sur GHCR (tag latest mouvant). On fait juste pull + up qui
# recupere la nouvelle image et recrée le container.
set -Eeuo pipefail

# Source PORT depuis l'env file synce par Infisical agent
# shellcheck disable=SC1091
source /etc/secrets/work.env

: "${PORT:?PORT manquant dans /etc/secrets/work.env}"

COMPOSE_DIR="/opt/vps-install/services/work"
cd "$COMPOSE_DIR"

HOST_PORT="$PORT" SERVICE_NAME="work" docker compose -p work pull
HOST_PORT="$PORT" SERVICE_NAME="work" docker compose -p work up -d

echo "[$(date -Iseconds)] work deploye (image GHCR latest)"
