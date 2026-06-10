#!/usr/bin/env bash
# Install Healthchecks.io self-hosted (monitoring crons).
# Service VPS uniquement par convention (pas server, pour eviter qu'un crash
# du home server fasse perdre les alertes du VPS).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/healthchecks/ :
#   - ADDRESS, DOMAIN, PORT          (port host, bind localhost)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - SECRET_KEY                     (Django, genere via openssl rand -hex 64)
#   - SUPERUSER_EMAIL                (admin login email)
#   - SUPERUSER_PASSWORD             (admin login password)
#   - SITE_NAME                      (optionnel, defaut "Healthchecks")
#   - SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, SMTP_USE_TLS  (optionnels)

set -euo pipefail

DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME} --env-file ${RUNTIME_ENV}"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

build_runtime_env() {
  : "${ADDRESS:?ADDRESS manquant}"
  : "${PORT:?PORT manquant}"

  local token domain pid env_slug host_uid host_gid
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: infi-token KO (creds /etc/infisical/* ou connectivite ?)"
    exit 1
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id)"
  env_slug="$(cat /etc/infisical/environment)"

  host_uid="$(id -u "$VPS_USER")"
  host_gid="$(id -g "$VPS_USER")"

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "ADDRESS=${ADDRESS}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "HOST_UID=${host_uid}"
    echo "HOST_GID=${host_gid}"
    infisical export \
      --domain="$domain" \
      --projectId="$pid" \
      --env="$env_slug" \
      --path="/services/${SERVICE_NAME}" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  for k in SECRET_KEY SUPERUSER_EMAIL SUPERUSER_PASSWORD; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent de /services/${SERVICE_NAME}/ dans Infisical Cloud."
    fi
  done
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    HOST_UID_VALUE="$(id -u "$VPS_USER")"
    HOST_GID_VALUE="$(id -g "$VPS_USER")"

    # DATA_DIR : SQLite DB + media uploads (badges). Owned VPS_USER.
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_DIR" \
      "$DATA_DIR/data"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    # Auto-creation idempotente du superuser via Django ORM.
    # L'image officielle ne supporte pas DJANGO_SUPERUSER_* a l'entrypoint, donc
    # on le fait nous-memes apres compose up. Re-run = update du pass + flags
    # (= utile si on change SUPERUSER_PASSWORD dans Infisical).
    SUPERUSER_EMAIL_VALUE="$(grep -E '^SUPERUSER_EMAIL=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    SUPERUSER_PASSWORD_VALUE="$(grep -E '^SUPERUSER_PASSWORD=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -n "$SUPERUSER_EMAIL_VALUE" && -n "$SUPERUSER_PASSWORD_VALUE" ]]; then
      echo "Attente du demarrage de Healthchecks pour creer/maj le superuser..."
      for i in $(seq 1 30); do
        if docker exec "$SERVICE_NAME" curl -fsS http://127.0.0.1:8000/api/v3/status/ >/dev/null 2>&1; then
          break
        fi
        sleep 2
      done

      echo "Setup superuser (${SUPERUSER_EMAIL_VALUE})..."
      docker exec -i \
        -e HC_EMAIL="$SUPERUSER_EMAIL_VALUE" \
        -e HC_PASSWORD="$SUPERUSER_PASSWORD_VALUE" \
        "$SERVICE_NAME" \
        ./manage.py shell <<'PYEOF' || echo "AVERTISSEMENT: setup superuser KO (cf logs container)"
import os
from django.contrib.auth.models import User
email = os.environ["HC_EMAIL"]
password = os.environ["HC_PASSWORD"]
user, created = User.objects.get_or_create(
    username=email,
    defaults={"email": email, "is_staff": True, "is_superuser": True},
)
user.set_password(password)
user.is_staff = True
user.is_superuser = True
user.email = email
user.save()
print(f"{'created' if created else 'updated'}: {email}")
PYEOF
    else
      echo "INFO: SUPERUSER_EMAIL/PASSWORD vides dans runtime.env, skip auto-creation."
      echo "  (tu pourras t'inscrire via https://${ADDRESS}/accounts/signup/)"
    fi

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/"
    echo "Ops data     : ${DATA_DIR}/data (SQLite DB + media)"
    echo
    echo "Login : ${SUPERUSER_EMAIL_VALUE:-(SUPERUSER_EMAIL absent)} / SUPERUSER_PASSWORD (Infisical)"
    echo
    echo "Puis dans l'UI :"
    echo "  1. Cree un projet (ex: 'VPS' ou 'Server'), recupere son ping_key"
    echo "  2. Mets-le dans Infisical /infra/<host_type>/HEALTHCHECKS_PING_KEY"
    echo "  3. Set /infra/shared/HEALTHCHECKS_URL_BASE=https://${ADDRESS}/ping"
    echo "  4. infisical-agent repolls toutes les 5min, ou systemctl restart"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans ${DATA_DIR}/data (rm -rf manuel pour purger)."
    ;;

  status)
    cd "$SERVICE_DIR"
    $COMPOSE ps 2>/dev/null || echo "Stack pas demarree."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
