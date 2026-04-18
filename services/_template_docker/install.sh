#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE
COMPOSE="docker compose -f $SERVICE_DIR/docker-compose.yml -p $SERVICE_NAME"

case "$ACTION" in
  install|update)
    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d
    ;;
  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down -v || true
    ;;
  status)
    $COMPOSE ps
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
