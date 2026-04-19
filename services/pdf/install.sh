#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

# Operationnel pur : pas de donnees utilisateur a backup. On reste sous
# /var/lib/services/<name>/ plutot que /home/$VPS_USER/data/.
DATA_DIR="/var/lib/services/$SERVICE_NAME"
COMPOSE="docker compose -f $SERVICE_DIR/docker-compose.yml -p $SERVICE_NAME"

export DATA_DIR

case "$ACTION" in
  install|update)
    install -d -m 755 \
      "$DATA_DIR" "$DATA_DIR/configs" "$DATA_DIR/logs" "$DATA_DIR/tessdata"
    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d
    ;;
  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down || true
    echo "Data preservee dans $DATA_DIR (supprime a la main pour purger)."
    ;;
  status)
    $COMPOSE ps
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
