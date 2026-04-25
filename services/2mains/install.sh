#!/usr/bin/env bash
# Install 2mains de femmes (Astro statique + backend formulaire).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/2mains/ :
#   - ADRESS=2mainsdefemmes.org   - DOMAIN=2mainsdefemmes.org
#   - PORT_SITE=8064              - PORT_MAIL=8065
#   - DNS_PROVIDER, DNS_TOKEN_NAME (token client, pas perso)
#   - SMTP_HOST, SMTP_PORT, SMTP_SECURE, SMTP_USER, SMTP_PASS, SMTP_FROM
#   - MAIL_TO, RATE_LIMIT_PER_HOUR, ALLOWED_ORIGIN
#
# Le webhook cote receiver attend aussi /services/webhooks/2mains/ avec
# REPO=aliceout/2mains, WEBHOOK_SECRET, SCRIPT=2mains.sh, PROVIDER=github,
# WORKFLOW=<nom workflow CI>, BRANCH=main.

set -euo pipefail

WEBHOOKS_HOOKS_DIR="/var/lib/services/webhooks/hooks"
HOOK_SRC="$SERVICE_DIR/hook.sh"
HOOK_DST="$WEBHOOKS_HOOKS_DIR/${SERVICE_NAME}.sh"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical."
  exit 1
fi
# Source pour avoir PORT_SITE / PORT_MAIL exposes au shell -> docker compose
# substitution. Bash strip les single-quotes, donc valeurs propres.
set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

: "${PORT_SITE:?PORT_SITE manquant dans $SECRETS_FILE}"
: "${PORT_MAIL:?PORT_MAIL manquant dans $SECRETS_FILE}"

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
    fi

    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" docker compose -p "$SERVICE_NAME" pull
    SERVICE_NAME="$SERVICE_NAME" docker compose -p "$SERVICE_NAME" up -d

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie."
    fi

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "Site:    http://127.0.0.1:${PORT_SITE} (proxied via nginx host)"
    echo "Mail:    http://127.0.0.1:${PORT_MAIL}/api/contact"
    ;;

  remove)
    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" docker compose -p "$SERVICE_NAME" down 2>/dev/null || true
    rm -f "$HOOK_DST"
    trigger_webhooks_update
    echo "Stack arretee + hook retire."
    ;;

  status)
    cd "$SERVICE_DIR"
    SERVICE_NAME="$SERVICE_NAME" docker compose -p "$SERVICE_NAME" ps 2>/dev/null \
      || echo "Stack pas demarree."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
