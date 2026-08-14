#!/usr/bin/env bash
# Install Tituba (fork de carnet : Astro SSR + Payload CMS + Postgres).
# 3 containers (db/payload/site), compose fourni par le repo de l'app,
# deploiement via le hook (clone + docker compose pull + up).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/tituba/ (framework) :
#   - ADDRESS, DOMAIN
#   - PORT_SITE (defaut 8067), PORT_PAYLOAD (defaut 8068)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#
# Cles app sous /services/tituba/<sous-dossier>/ (lues par scripts/deploy.sh
# du repo, comme carnet) : POSTGRES_*, PAYLOAD_SECRET, SMTP_*,
# INTERNAL_PROXY_SECRET, et les optionnelles (cf rapport / .env.example).
#
# Les creds Cloud du framework sont passees au deploy.sh via
# /home/$VPS_USER/.config/infisical/tituba.env (meme identite machine que le
# framework, lit /etc/infisical/).
#
# Le webhook cote receiver attend /services/tituba/hook/ avec
# REPO=aliceout/Tituba, WEBHOOK_SECRET, SCRIPT=tituba.sh, GIT_PROVIDER=github,
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
    : "${ADDRESS:?ADDRESS manquant}"

    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 /var/www
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "$DEPLOY_DIR"

    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
      echo "$VPS_USER ajoute au groupe docker (effet au prochain login)."
    fi

    # Bind mounts data. Les uids sont FIXES par les images :
    #   - postgres:16-alpine  -> uid 70
    #   - payload (Dockerfile) -> user 'nextjs' uid 1001 (DIFFERE de carnet=1000 !)
    install -d -m 755 -o "$VPS_USER" -g "$VPS_USER" "$DATA_DIR"
    install -d -m 700 -o 70   -g 70   "$DATA_DIR/postgres"
    install -d -m 755 -o 1001 -g 1001 "$DATA_DIR/payload-media"

    # Creds Cloud du framework pour tituba (lus par deploy.sh du repo).
    # Single Infisical : meme identite que le framework, qui fetch ses
    # sous-dossiers /services/tituba/{...} via la meme machine identity.
    FRAMEWORK_ADDRESS="$(cat /etc/infisical/address 2>/dev/null || echo 'https://app.infisical.com')"
    FRAMEWORK_PROJECT_ID="$(cat /etc/infisical/project-id 2>/dev/null || true)"
    FRAMEWORK_ENV="$(cat /etc/infisical/environment 2>/dev/null || true)"
    FRAMEWORK_CLIENT_ID="$(cat /etc/infisical/client-id 2>/dev/null || true)"
    FRAMEWORK_CLIENT_SECRET="$(cat /etc/infisical/client-secret 2>/dev/null || true)"
    if [[ -z "$FRAMEWORK_PROJECT_ID" || -z "$FRAMEWORK_CLIENT_ID" || -z "$FRAMEWORK_CLIENT_SECRET" ]]; then
      echo "ERREUR: creds Infisical framework manquantes (/etc/infisical/{project-id,client-id,client-secret})"
      exit 1
    fi

    install -d -o "$VPS_USER" -g "$VPS_USER" -m 700 "$CREDS_DIR"
    umask 077
    cat > "$CREDS_FILE" <<EOF
INFISICAL_API_URL=${FRAMEWORK_ADDRESS}
INFISICAL_PROJECT_ID=${FRAMEWORK_PROJECT_ID}
INFISICAL_CLIENT_ID=${FRAMEWORK_CLIENT_ID}
INFISICAL_CLIENT_SECRET=${FRAMEWORK_CLIENT_SECRET}
INFISICAL_ENV=${FRAMEWORK_ENV}
EOF
    chown "$VPS_USER:$VPS_USER" "$CREDS_FILE"
    chmod 600 "$CREDS_FILE"
    echo "Creds Infisical tituba ecrits: $CREDS_FILE"

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
    echo "Premier deploy tituba via le hook (clone + pull GHCR + up)..."
    runuser -u "$VPS_USER" -- bash "$HOOK_SRC" || {
      echo "AVERTISSEMENT: premier deploy KO. Relance a la main :"
      echo "  sudo -u $VPS_USER bash $HOOK_DST"
    }
    echo
    echo "=== ${SERVICE_NAME} : 1er demarrage ==="
    echo "IMPORTANT : la base est migree mais VIDE. Cree le compte admin (une fois) :"
    echo "  docker exec -e SEED_ROOT_EMAIL=<toi@ex.org> -e SEED_ROOT_PASSWORD='<12+ car>' \\"
    echo "    ${SERVICE_NAME}-payload ./node_modules/.bin/tsx scripts/seed-config.ts"
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
    echo "=== tituba ==="
    if [[ -d "$DEPLOY_DIR/.git" ]]; then
      echo "Repo: $DEPLOY_DIR ($(cd "$DEPLOY_DIR" && git log -1 --oneline 2>/dev/null || echo 'n/a'))"
    else
      echo "Repo: absent ($DEPLOY_DIR)"
    fi
    echo
    if command -v docker >/dev/null 2>&1; then
      docker ps --filter "name=${SERVICE_NAME}" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    fi
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
