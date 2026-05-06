#!/usr/bin/env bash
# Install 2mains de femmes (Astro SSR + Payload CMS + mail backend + Postgres).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/2mains/ :
#   - ADRESS=2mainsdefemmes.org
#   - DOMAIN=2mainsdefemmes.org
#   - PORT_SITE=8064
#   - PORT_MAIL=8065
#   - PORT_PAYLOAD=8066
#   - DNS_PROVIDER=infomaniak (ou ovh)
#   - DNS_TOKEN_NAME=<label client>
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted, projet 2mains)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet 2mains, env prod,
# racine flat (le user remplit) :
#   - POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#   - PAYLOAD_SECRET, PAYLOAD_PUBLIC_SERVER_URL
#   - ASTRO_PUBLIC_PAYLOAD_URL
#   - HELLOASSO_DON, HELLOASSO_ADHESION, HELLOASSO_NEWSLETTER
#   - SMTP_HOST, SMTP_PORT, SMTP_SECURE, SMTP_USER, SMTP_PASS, SMTP_FROM
#   - MAIL_TO, RATE_LIMIT_PER_HOUR, ALLOWED_ORIGIN
#
# Le webhook cote receiver attend /services/2mains/hook/ avec
# REPO=aliceout/2mains, WEBHOOK_SECRET, SCRIPT=2mains.sh, GIT_PROVIDER=github,
# WORKFLOW="Docker build", BRANCH=main.

set -euo pipefail

WEBHOOKS_HOOKS_DIR="/var/lib/services/webhooks/hooks"
HOOK_SRC="$SERVICE_DIR/hook.sh"
HOOK_DST="$WEBHOOKS_HOOKS_DIR/${SERVICE_NAME}.sh"
DEPLOY_DIR="/var/www/${SERVICE_NAME}"
DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
CREDS_DIR="/home/${VPS_USER}/.config/infisical"
CREDS_FILE="${CREDS_DIR}/${SERVICE_NAME}.env"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
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
    : "${ADRESS:?ADRESS manquant}"
    : "${INFISICAL_API_URL:?INFISICAL_API_URL manquant}"
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

    # Bind mounts data : Postgres run en uid 70 (alpine), Payload media en
    # uid 1000 (node user). Ces uids sont fixes par les images.
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR"
    install -d -m 700 -o 70   -g 70   "$DATA_DIR/postgres"
    install -d -m 755 -o 1000 -g 1000 "$DATA_DIR/payload-media"

    # Creds Infisical self-hosted pour 2mains (lus par deploy.sh du repo).
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 700 "$CREDS_DIR"
    umask 077
    cat > "$CREDS_FILE" <<EOF
INFISICAL_API_URL=${INFISICAL_API_URL}
INFISICAL_PROJECT_ID=${INFISICAL_PROJECT_ID}
INFISICAL_CLIENT_ID=${INFISICAL_CLIENT_ID}
INFISICAL_CLIENT_SECRET=${INFISICAL_CLIENT_SECRET}
INFISICAL_ENV=${INFISICAL_ENV}
EOF
    chown "$VPS_USER:$VPS_USER" "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    echo "Creds Infisical 2mains ecrits: $CREDS_FILE"

    if [[ -d "$WEBHOOKS_HOOKS_DIR" ]]; then
      install -m 755 -o "$VPS_USER" -g "$VPS_USER" "$HOOK_SRC" "$HOOK_DST"
      echo "Hook publie: $HOOK_DST"
      trigger_webhooks_update
    else
      echo "INFO: webhooks pas encore installe, hook non publie. Lance"
      echo "  services install webhooks  puis  services update ${SERVICE_NAME}"
    fi

    # Premier deploy : clone du repo + docker compose pull + up via le hook.
    # Idempotent : si le repo est deja la, le hook fait fetch + reset + redeploy.
    echo "Premier deploy 2mains via le hook (clone + pull GHCR + up)..."
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
        "cd '$(dirname "$compose_file")' && docker compose -f '$(basename "$compose_file")' down" \
        2>/dev/null || true
    fi
    rm -f "$HOOK_DST"
    rm -f "$CREDS_FILE"
    rm -rf "$DEPLOY_DIR"
    trigger_webhooks_update
    echo "Hook + creds + repo source retires, stack docker arretee."
    echo "Data preservee dans ${DATA_DIR} (rm -rf manuel pour purger)."
    ;;

  status)
    echo "=== 2mains ==="
    if [[ -d "$DEPLOY_DIR/.git" ]]; then
      echo "Repo: $DEPLOY_DIR ($(cd "$DEPLOY_DIR" && git log -1 --oneline 2>/dev/null || echo 'n/a'))"
    else
      echo "Repo: absent ($DEPLOY_DIR)"
    fi
    echo
    if command -v docker >/dev/null 2>&1; then
      docker ps --filter "name=2mains" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    fi
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
