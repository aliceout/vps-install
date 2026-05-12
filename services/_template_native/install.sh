#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE
# shellcheck disable=SC1091
source "$SERVICE_DIR/service.conf"

: "${UNIT_NAME:?UNIT_NAME doit etre defini dans service.conf (ex: UNIT_NAME=monservice.service)}"

UNIT_PATH="/etc/systemd/system/$UNIT_NAME"

install_unit() {
  cp "$SERVICE_DIR/unit.service" "$UNIT_PATH"
  chmod 644 "$UNIT_PATH"
  systemctl daemon-reload
  systemctl enable --now "$UNIT_NAME"
}

remove_unit() {
  systemctl disable --now "$UNIT_NAME" || true
  rm -f "$UNIT_PATH"
  systemctl daemon-reload
}

case "$ACTION" in
  install|update)
    install_unit
    systemctl restart "$UNIT_NAME"
    ;;
  remove)
    remove_unit
    ;;
  status)
    systemctl status --no-pager "$UNIT_NAME" || true
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
