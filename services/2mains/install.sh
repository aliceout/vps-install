#!/usr/bin/env bash
# Install 2mains de femmes (Astro statique + backend formulaire).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/2mains/ :
#   - ADRESS=2mainsdefemmes.org
#   - DOMAIN=2mainsdefemmes.org
#   - PORT_SITE=8064
#   - PORT_MAIL=8065
#   - DNS_PROVIDER=infomaniak (ou ovh)
#   - DNS_TOKEN_NAME=<label client>
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted, projet 2mains)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet 2mains, env prod,
# racine flat :
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
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

build_runtime_env() {
  : "${ADRESS:?ADRESS manquant}"
  : "${PORT_SITE:?PORT_SITE manquant}"
  : "${PORT_MAIL:?PORT_MAIL manquant}"
  : "${INFISICAL_API_URL:?INFISICAL_API_URL manquant}"
  : "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID manquant}"
  : "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID manquant}"
  : "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET manquant}"
  : "${INFISICAL_ENV:?INFISICAL_ENV manquant}"

  echo "Login Infisical self-hosted (${INFISICAL_API_URL})..."
  local token
  token="$(infisical login \
    --method=universal-auth \
    --domain="$INFISICAL_API_URL" \
    --client-id="$INFISICAL_CLIENT_ID" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --plain --silent 2>/dev/null)"
  [[ -n "$token" ]] || { echo "ERREUR: login Infisical self-hosted echoue"; exit 1; }

  install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT_SITE=${PORT_SITE}"
    echo "PORT_MAIL=${PORT_MAIL}"
    # App secrets : SMTP_*, MAIL_TO, RATE_LIMIT_PER_HOUR, ALLOWED_ORIGIN
    infisical export \
      --domain="$INFISICAL_API_URL" \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path="/" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  # Owner choupi pour que hook.sh (run en VPS_USER au webhook deploy) puisse
  # reecrire le fichier sans Permission denied.
  chown "$VPS_USER:$VPS_USER" "$RUNTIME_ENV"
  chmod 600 "$RUNTIME_ENV"

  if ! grep -q '^SMTP_HOST=' "$RUNTIME_ENV"; then
    echo "AVERTISSEMENT: SMTP_HOST absent du self-hosted. Verifie le projet 2mains sur ${INFISICAL_API_URL}."
  fi
}

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

    build_runtime_env

    cd "$SERVICE_DIR"
    docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" pull
    docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" up -d

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie."
    fi

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "Site:    127.0.0.1:${PORT_SITE} (proxied via nginx)"
    echo "Mail:    127.0.0.1:${PORT_MAIL}/api/contact"
    ;;

  remove)
    cd "$SERVICE_DIR"
    if [[ -s "$RUNTIME_ENV" ]]; then
      docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" down 2>/dev/null || true
    else
      docker compose -p "$SERVICE_NAME" down 2>/dev/null || true
    fi
    rm -f "$HOOK_DST" "$RUNTIME_ENV"
    trigger_webhooks_update
    echo "Stack arretee + hook + runtime.env retires."
    ;;

  status)
    cd "$SERVICE_DIR"
    if [[ -s "$RUNTIME_ENV" ]]; then
      docker compose --env-file "$RUNTIME_ENV" -p "$SERVICE_NAME" ps 2>/dev/null \
        || echo "Stack pas demarree."
    else
      echo "runtime.env absent (service pas installe ou supprime)."
    fi
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
