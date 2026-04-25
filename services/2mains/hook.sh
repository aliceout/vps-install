#!/usr/bin/env bash
# Webhook hook 2mains. Source les vars cloud Infisical, pull les images
# GHCR, recree les containers.
set -Eeuo pipefail

set -a
# shellcheck disable=SC1091
source /etc/secrets/2mains.env
set +a

: "${PORT_SITE:?PORT_SITE manquant dans /etc/secrets/2mains.env}"
: "${PORT_MAIL:?PORT_MAIL manquant dans /etc/secrets/2mains.env}"

COMPOSE_DIR="/opt/vps-install/services/2mains"
cd "$COMPOSE_DIR"

SERVICE_NAME="2mains" docker compose -p 2mains pull
SERVICE_NAME="2mains" docker compose -p 2mains up -d

echo "[$(date -Iseconds)] 2mains deploye (images GHCR latest)"
