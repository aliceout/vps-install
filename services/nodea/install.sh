#!/usr/bin/env bash
# Install Nodea (app Dockerisee, E2E chiffree) sur le VPS.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/nodea/ :
#   - DOMAIN                  (ex: nodea.app) - apex pour le cert wildcard
#   - ADDRESS                  (ex: nodea.app) - FQDN du vhost
#   - PORT                    (ex: 8061) - port host du container web
#   - DNS_PROVIDER            infomaniak | ovh
#   - DNS_TOKEN_NAME          label sous /certbot/<provider>/
#   - INFISICAL_API_URL       (ex: https://env.backlice.dev) - Infisical self-hosted
#   - INFISICAL_PROJECT_ID    - project id cote self-hosted (projet Nodea)
#   - INFISICAL_CLIENT_ID     - machine identity cote self-hosted
#   - INFISICAL_CLIENT_SECRET
#   - INFISICAL_ENV           (ex: prod)
#
# Les INFISICAL_* sont ecrits dans /home/$VPS_USER/.config/infisical/nodea.env
# et consommes par deploy.sh (dans le repo Nodea) qui fetch les vraies cles
# app (COOKIE_SECRET, POSTGRES_PASSWORD, SMTP_*, etc.) depuis le self-hosted.
#
# Le webhook cote receiver attend aussi /services/nodea/hook/ avec
# REPO=aliceout/Nodea, WEBHOOK_SECRET=<hmac>, SCRIPT=nodea.sh,
# PROVIDER=github, WORKFLOW="Docker build", BRANCH=main
set -euo pipefail

WEBHOOKS_HOOKS_DIR="/var/lib/services/webhooks/hooks"
HOOK_SRC="$SERVICE_DIR/hook.sh"
HOOK_DST="$WEBHOOKS_HOOKS_DIR/${SERVICE_NAME}.sh"
DEPLOY_DIR="/var/www/${SERVICE_NAME}"
NODEA_CREDS_DIR="/home/${VPS_USER}/.config/infisical"
NODEA_CREDS_FILE="${NODEA_CREDS_DIR}/${SERVICE_NAME}.env"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie les cles sous /services/${SERVICE_NAME}/ dans Infisical."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

trigger_webhooks_update() {
  if [[ -x /opt/vps-install/scripts/service.sh ]] && \
     [[ -d /var/lib/services/webhooks ]]; then
    bash /opt/vps-install/scripts/service.sh update webhooks 2>/dev/null \
      || echo "AVERTISSEMENT: services update webhooks a echoue (ignore)"
  fi
}

find_compose_file() {
  [[ -d "$DEPLOY_DIR" ]] || return 1
  find "$DEPLOY_DIR" -maxdepth 3 -type f \
    \( -name 'docker-compose.yml' -o -name 'compose.yml' \) 2>/dev/null \
    | head -n1
}

case "$ACTION" in
  install|update)
    : "${INFISICAL_API_URL:?INFISICAL_API_URL manquant dans $SECRETS_FILE}"
    : "${INFISICAL_PROJECT_ID:?INFISICAL_PROJECT_ID manquant}"
    : "${INFISICAL_CLIENT_ID:?INFISICAL_CLIENT_ID manquant}"
    : "${INFISICAL_CLIENT_SECRET:?INFISICAL_CLIENT_SECRET manquant}"
    : "${INFISICAL_ENV:?INFISICAL_ENV manquant}"

    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 /var/www
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "$DEPLOY_DIR"

    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
      echo "$VPS_USER ajoute au groupe docker (effet au prochain login)."
    fi

    # Creds Infisical self-hosted pour Nodea (lus par deploy.sh).
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 700 "$NODEA_CREDS_DIR"
    umask 077
    cat > "$NODEA_CREDS_FILE" <<EOF
INFISICAL_API_URL=${INFISICAL_API_URL}
INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID}
INFISICAL_CLIENT_ID=${INFISICAL_CLIENT_ID}
INFISICAL_CLIENT_SECRET=${INFISICAL_CLIENT_SECRET}
INFISICAL_ENV=${INFISICAL_ENV}
EOF
    chown "$VPS_USER:$VPS_USER" "$NODEA_CREDS_FILE"
    chmod 600 "$NODEA_CREDS_FILE"
    echo "Creds Infisical Nodea ecrits: $NODEA_CREDS_FILE"

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie. Lance"
      echo "  services install webhooks  puis  services update ${SERVICE_NAME}"
      echo "pour rebrancher."
    fi

    echo "Premier deploy Nodea via le hook (clone + build containers + up, peut prendre plusieurs minutes)..."
    runuser -u "$VPS_USER" -- bash "$HOOK_SRC" || {
      echo "AVERTISSEMENT: premier deploy KO. Relance a la main :"
      echo "  sudo -u $VPS_USER bash $HOOK_DST"
    }
    ;;

  remove)
    compose_file="$(find_compose_file || true)"
    if [[ -n "$compose_file" ]] && command -v docker >/dev/null 2>&1; then
      echo "Arret de la stack docker ($compose_file)..."
      runuser -u "$VPS_USER" -- bash -c \
        "cd '$(dirname "$compose_file")' && docker compose -f '$(basename "$compose_file")' down -v" \
        2>/dev/null || true
    fi
    rm -f "$HOOK_DST"
    rm -f "$NODEA_CREDS_FILE"
    rm -rf "$DEPLOY_DIR"
    trigger_webhooks_update
    echo "Hook + creds + repo source retires, stack docker arretee."
    ;;

  status)
    echo "=== Nodea ==="
    if [[ -d "$DEPLOY_DIR/.git" ]]; then
      echo "Repo: $DEPLOY_DIR ($(cd "$DEPLOY_DIR" && git log -1 --oneline 2>/dev/null || echo 'n/a'))"
    else
      echo "Repo: absent ($DEPLOY_DIR)"
    fi
    echo
    if command -v docker >/dev/null 2>&1; then
      docker ps --filter "name=nodea" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    fi
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
