#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

DATA_DIR="/var/lib/services/$SERVICE_NAME"
HOOKS_DIR="$DATA_DIR/hooks"
LOG_DIR="$DATA_DIR/log"
UNIT="/etc/systemd/system/${SERVICE_NAME}.service"

: "${VPS_USER:?VPS_USER manquant}"

case "$ACTION" in
  install|update)
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR" "$HOOKS_DIR" "$LOG_DIR"
    install -m 644 -o "$VPS_USER" -g "$VPS_USER" "$SERVICE_DIR/app.js" "$DATA_DIR/app.js"

    cat > "$UNIT" <<EOF
[Unit]
Description=GitHub webhooks receiver
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${VPS_USER}
Group=${VPS_USER}
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${SECRETS_FILE}
Environment=HOOKS_DIR=${HOOKS_DIR}
Environment=LOG_DIR=${LOG_DIR}
ExecStart=/usr/bin/node ${DATA_DIR}/app.js
Restart=on-failure
RestartSec=5s
# Harden un peu
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=${DATA_DIR}
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT"

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null
    systemctl restart "${SERVICE_NAME}.service"

    echo "Webhooks service demarre. Scripts de deploy a deposer dans ${HOOKS_DIR}/"
    ;;

  remove)
    systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload
    echo "Service arrete. Data preservee dans ${DATA_DIR} (supprime a la main pour purger)."
    ;;

  status)
    systemctl status "${SERVICE_NAME}.service" --no-pager || true
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
