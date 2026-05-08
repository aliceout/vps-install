#!/usr/bin/env bash
# Install Transmission via OpenVPN (haugene/transmission-openvpn) +
# tinyauth (form-based auth devant le webUI).
# Service home server uniquement.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/torrent/ :
#   - ADDRESS, DOMAIN, PORT, AUTH_PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - INFISICAL_API_URL, _PROJECT_ID, _CLIENT_ID, _CLIENT_SECRET, _ENV
#     (creds vers self-hosted)
#
# Cles attendues dans Infisical SELF-HOSTED sous projet torrent, racine flat :
#   - DATA_DIR                    (ex: /media/pi/media/transmission)
#   - OPENVPN_PROVIDER, OPENVPN_CONFIG
#   - OPENVPN_USERNAME, OPENVPN_PASSWORD
#   - TINYAUTH_USERS              (format: user:bcrypt-hash, plusieurs separes par virgule)
#                                 generation : docker run --rm ghcr.io/steveiliop56/tinyauth:latest \
#                                              user create -u <user> -p <password>
#                                 (tinyauth v5+ : la cle de cookie est auto-generee
#                                  et persistee dans /app/data/tinyauth.db, donc
#                                  pas de SECRET a fournir)

set -euo pipefail

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
  : "${AUTH_PORT:?AUTH_PORT manquant (port pour tinyauth, ex 9092)}"
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
    --plain </dev/null 2>/dev/null)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: login Infisical self-hosted echoue"
    exit 1
  fi

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "AUTH_PORT=${AUTH_PORT}"
    echo "ADDRESS=${ADDRESS}"
    infisical export \
      --domain="$INFISICAL_API_URL" \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path="/" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  for k in DATA_DIR OPENVPN_PROVIDER OPENVPN_CONFIG OPENVPN_USERNAME OPENVPN_PASSWORD \
           TINYAUTH_USERS; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent du self-hosted. Verifie /${SERVICE_NAME}/ sur ${INFISICAL_API_URL}."
    fi
  done
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    DATA_DIR_VALUE="$(grep -E '^DATA_DIR=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$DATA_DIR_VALUE" ]]; then
      echo "ERREUR: DATA_DIR vide dans le runtime.env. Set-le cote Infisical self-hosted."
      exit 1
    fi
    if [[ ! -d "$DATA_DIR_VALUE" ]]; then
      echo "AVERTISSEMENT: $DATA_DIR_VALUE n'existe pas. Cree-le a la main avant le up :"
      echo "  sudo install -d -m 755 -o $VPS_USER -g $VPS_USER '$DATA_DIR_VALUE'"
      exit 1
    fi

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL : https://${ADDRESS}/  (login form via tinyauth)"
    echo "Data : ${DATA_DIR_VALUE}"
    echo
    echo "Verif VPN actif :"
    echo "  docker exec ${SERVICE_NAME} curl -s https://ipinfo.io/ip"
    echo "  → doit afficher l'IP du VPN, pas ton IP publique reelle."
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans le DATA_DIR Infisical."
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
