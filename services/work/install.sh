#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

WEBHOOKS_HOOKS_DIR="/var/lib/services/webhooks/hooks"
HOOK_SRC="$SERVICE_DIR/hook.sh"
HOOK_DST="$WEBHOOKS_HOOKS_DIR/${SERVICE_NAME}.sh"

: "${VPS_USER:?VPS_USER manquant}"

# Charge la config depuis l'env file (DIR, APP, etc. viennent de la)
if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie que les cles sont presentes"
  echo "dans Infisical sous /services/${SERVICE_NAME}/ et que l'agent a sync."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"
: "${DIR:?DIR manquant dans $SECRETS_FILE}"
: "${APP:?APP manquant dans $SECRETS_FILE}"

trigger_webhooks_update() {
  if [[ -x /opt/vps-install/scripts/service.sh ]] && \
     [[ -d /var/lib/services/webhooks ]]; then
    bash /opt/vps-install/scripts/service.sh update webhooks 2>/dev/null \
      || echo "AVERTISSEMENT: services update webhooks a echoue (ignore)"
  fi
}

case "$ACTION" in
  install|update)
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 /var/www
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "$(dirname "$DIR")"
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "$DIR"

    runuser -u "$VPS_USER" -- bash "$HOOK_SRC"

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie. Lance"
      echo "  services install webhooks  puis  services update ${SERVICE_NAME}"
      echo "pour rebrancher."
    fi
    ;;

  remove)
    runuser -u "$VPS_USER" -- pm2 delete "$APP" 2>/dev/null || true
    runuser -u "$VPS_USER" -- pm2 save 2>/dev/null || true
    rm -f "$HOOK_DST"
    trigger_webhooks_update
    echo "pm2 stoppe + hook retire de webhooks."
    echo "Code source preserve dans $DIR (a rm -rf manuel pour purger)."
    ;;

  status)
    runuser -u "$VPS_USER" -- pm2 list 2>/dev/null \
      | awk -v app="$APP" '$0 ~ app {print}' \
      || echo "${APP}: pas dans pm2"
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
