#!/usr/bin/env bash
# Install Work-resume (CV Next.js, image officielle GHCR, sans deploy.sh
# applicatif - tout est dans l'image, le compose.yml est bundle ici).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/work/ :
#   - ADRESS, DOMAIN, PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#
# Le webhook cote receiver attend aussi /services/webhooks/work/ avec
# REPO=aliceout/work-resume, WEBHOOK_SECRET=<hmac>, SCRIPT=work.sh,
# PROVIDER=github, WORKFLOW="Docker build", BRANCH=master
#
# Aucun secret applicatif au runtime (portfolio statique, tout en JSON
# baked dans l'image au build CI).

set -euo pipefail

WEBHOOKS_HOOKS_DIR="/var/lib/services/webhooks/hooks"
HOOK_SRC="$SERVICE_DIR/hook.sh"
HOOK_DST="$WEBHOOKS_HOOKS_DIR/${SERVICE_NAME}.sh"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME}"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"
: "${PORT:?PORT manquant dans $SECRETS_FILE}"

trigger_webhooks_update() {
  if [[ -x /opt/vps-install/scripts/service.sh ]] && \
     [[ -d /var/lib/services/webhooks ]]; then
    bash /opt/vps-install/scripts/service.sh update webhooks 2>/dev/null \
      || echo "AVERTISSEMENT: services update webhooks a echoue (ignore)"
  fi
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
      echo "$VPS_USER ajoute au groupe docker (effet au prochain login)."
    fi

    cd "$SERVICE_DIR"
    HOST_PORT="$PORT" SERVICE_NAME="$SERVICE_NAME" $COMPOSE pull
    HOST_PORT="$PORT" SERVICE_NAME="$SERVICE_NAME" $COMPOSE up -d

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie. Lance"
      echo "  services install webhooks  puis  services update ${SERVICE_NAME}"
    fi
    ;;

  remove)
    cd "$SERVICE_DIR"
    HOST_PORT="$PORT" SERVICE_NAME="$SERVICE_NAME" $COMPOSE down 2>/dev/null || true
    rm -f "$HOOK_DST"
    trigger_webhooks_update
    echo "Stack arretee + hook retire."
    ;;

  status)
    cd "$SERVICE_DIR"
    HOST_PORT="$PORT" SERVICE_NAME="$SERVICE_NAME" $COMPOSE ps 2>/dev/null \
      || echo "Stack pas demarree."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
