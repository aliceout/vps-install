#!/usr/bin/env bash
# Install Transmission via Gluetun (ProtonVPN WireGuard + NAT-PMP port-forwarding)
# + tinyauth (form-based auth devant le webUI).
# Service home server uniquement.
#
# Architecture (cf docker-compose.yml) :
#   gluetun       : VPN WG/Proton + NAT-PMP port-fwd + kill-switch nftables
#   transmission  : BitTorrent, partage le namespace reseau gluetun
#   tinyauth      : form auth devant Transmission via nginx auth_request
#
# Le hook update-port.sh est appele par gluetun a chaque (ré)allocation de
# port forwarded : il push le nouveau port dans Transmission via RPC.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/torrent/ :
#   - ADDRESS, DOMAIN, PORT, AUTH_PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DATA_DIR                    (ex: /media/pi/media/transmission)
#   - VPN_SERVICE_PROVIDER        (ex "protonvpn", cf doc gluetun pour autres)
#   - VPN_TYPE                    ("wireguard" ou "openvpn")
#   - VPN_PORT_FORWARDING_PROVIDER (ex "protonvpn", souvent = VPN_SERVICE_PROVIDER)
#   - WIREGUARD_PRIVATE_KEY       (generer depuis ProtonVPN dashboard :
#                                  Account -> WireGuard -> Create config)
#   - WIREGUARD_ADDRESSES         (ex "10.2.0.2/32" pour Proton)
#   - SERVER_COUNTRIES            (ex "Switzerland" ou "Switzerland,Netherlands")
#   - LOCAL_NETWORK               (optionnel, defaut "192.168.1.0/24")
#   - TINYAUTH_USERS              (format: user:bcrypt-hash, plusieurs separes
#                                  par virgule. Generation :
#                                  docker run --rm ghcr.io/steveiliop56/tinyauth:latest \
#                                    user create -u <user> -p <password>)

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

  local token domain pid env_slug
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: infi-token KO (creds /etc/infisical/* ou connectivite ?)"
    exit 1
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id)"
  env_slug="$(cat /etc/infisical/environment)"

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "SERVICE_DIR=${SERVICE_DIR}"
    echo "PORT=${PORT}"
    echo "AUTH_PORT=${AUTH_PORT}"
    echo "ADDRESS=${ADDRESS}"
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

  for k in DATA_DIR VPN_SERVICE_PROVIDER VPN_TYPE VPN_PORT_FORWARDING_PROVIDER \
           WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES SERVER_COUNTRIES TINYAUTH_USERS; do
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

    DATA_DIR_VALUE="$(grep -E '^DATA_DIR=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$DATA_DIR_VALUE" ]]; then
      echo "ERREUR: DATA_DIR vide dans le runtime.env. Set-le sous /services/${SERVICE_NAME}/ en Infisical Cloud."
      exit 1
    fi
    if [[ ! -d "$DATA_DIR_VALUE" ]]; then
      echo "ERREUR: $DATA_DIR_VALUE n'existe pas. Cree-le a la main avant le up :"
      echo "  sudo install -d -m 755 -o $VPS_USER -g $VPS_USER '$DATA_DIR_VALUE'"
      exit 1
    fi

    # Layout sous DATA_DIR : un sous-dir par container, perms VPS_USER.
    HOST_UID_VALUE="$(id -u "$VPS_USER")"
    HOST_GID_VALUE="$(id -g "$VPS_USER")"
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_DIR_VALUE/gluetun" \
      "$DATA_DIR_VALUE/transmission" \
      "$DATA_DIR_VALUE/downloads" \
      "$DATA_DIR_VALUE/watch" \
      "$DATA_DIR_VALUE/tinyauth"

    chmod +x "$SERVICE_DIR/update-port.sh"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/  (login form via tinyauth)"
    echo "Data         : ${DATA_DIR_VALUE}/{gluetun,transmission,downloads,watch,tinyauth}"
    echo
    echo "Verif VPN actif (= IP publique = IP Proton) :"
    echo "  docker exec ${SERVICE_NAME}-vpn wget -qO- https://ipinfo.io/ip"
    echo
    echo "Verif port forwarded (gluetun -> Transmission) :"
    echo "  docker logs ${SERVICE_NAME}-vpn 2>&1 | grep -i 'port forward'"
    echo "  docker logs ${SERVICE_NAME}-vpn 2>&1 | grep 'update-port'"
    echo "  cat ${DATA_DIR_VALUE}/gluetun/forwarded_port"
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
