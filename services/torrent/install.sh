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
# Layout disk :
#   DATA_DIR  (auto-cale sur /home/$VPS_USER/data/torrent) :
#     - gluetun/        etat gluetun + forwarded_port file
#     - transmission/   config Transmission (settings.json, torrents/, resume/)
#     - tinyauth/       SQLite tinyauth
#   DATA_PATH (Infisical, libre choix) :
#     - downloads/      fichiers telecharges
#     - watch/          .torrent a auto-charger
#
# Cles attendues dans Infisical CLOUD sous /services/torrent/ :
#   - ADDRESS, DOMAIN, PORT, AUTH_PORT
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - DATA_PATH                   chemin host des downloads + watch
#                                 (ex: /media/pi/media/transmission)
#   - VPN_SERVICE_PROVIDER        (ex "protonvpn")
#   - VPN_TYPE                    ("wireguard" ou "openvpn")
#   - VPN_PORT_FORWARDING_PROVIDER (ex "protonvpn")
#   - WIREGUARD_PRIVATE_KEY       (Proton dashboard -> WG config)
#   - WIREGUARD_ADDRESSES         (ex "10.2.0.2/32")
#   - SERVER_COUNTRIES            (ex "Switzerland" ou "Switzerland,Netherlands")
#   - LOCAL_NETWORK               (optionnel, defaut "192.168.1.0/24")
#   - TINYAUTH_USERS              (format user:bcrypt-hash, virgule-separe)

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
    echo "DATA_DIR=${DATA_DIR}"
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

  for k in DATA_PATH VPN_SERVICE_PROVIDER VPN_TYPE VPN_PORT_FORWARDING_PROVIDER \
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

    DATA_PATH_VALUE="$(grep -E '^DATA_PATH=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$DATA_PATH_VALUE" ]]; then
      echo "ERREUR: DATA_PATH vide dans le runtime.env. Set-le sous /services/${SERVICE_NAME}/ en Infisical Cloud."
      echo "  Ex: /media/pi/media/transmission"
      exit 1
    fi
    if [[ ! -d "$DATA_PATH_VALUE" ]]; then
      echo "ERREUR: $DATA_PATH_VALUE n'existe pas. Cree-le :"
      echo "  sudo install -d -m 755 -o $VPS_USER -g $VPS_USER '$DATA_PATH_VALUE'"
      exit 1
    fi

    HOST_UID_VALUE="$(id -u "$VPS_USER")"
    HOST_GID_VALUE="$(id -g "$VPS_USER")"

    # DATA_DIR : ops data framework (gluetun state, transmission config,
    # tinyauth SQLite). Sous /home/$VPS_USER/data/$SERVICE_NAME, owned VPS_USER.
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_DIR" \
      "$DATA_DIR/gluetun" \
      "$DATA_DIR/transmission" \
      "$DATA_DIR/tinyauth" \
      "$DATA_DIR/web-control"

    # DATA_PATH : donnees user (downloads + watch). Sous-dirs crees si absents.
    install -d -m 755 -o "$HOST_UID_VALUE" -g "$HOST_GID_VALUE" \
      "$DATA_PATH_VALUE/downloads" \
      "$DATA_PATH_VALUE/watch"

    # Download transmission-web-control (UI alt plus moderne que le default
    # Transmission). Pas bundle dans linuxserver/transmission, on l'install
    # nous-meme depuis github releases (master branch, repo statique HTML/JS).
    # Re-download a chaque install/update pour avoir la derniere version.
    echo "Install transmission-web-control UI..."
    find "$DATA_DIR/web-control" -mindepth 1 -delete 2>/dev/null || true
    if curl -fsSL https://github.com/transmission-web-control/transmission-web-control/archive/refs/heads/master.tar.gz \
        | tar -xz --strip-components=2 -C "$DATA_DIR/web-control" \
            transmission-web-control-master/src; then
      chown -R "$HOST_UID_VALUE:$HOST_GID_VALUE" "$DATA_DIR/web-control"
    else
      echo "AVERTISSEMENT: download transmission-web-control echoue, fallback sur UI defaut Transmission"
    fi

    chmod +x "$SERVICE_DIR/update-port.sh"

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/  (login form via tinyauth)"
    echo "Ops data     : ${DATA_DIR} (gluetun, transmission config, tinyauth)"
    echo "User data    : ${DATA_PATH_VALUE}/{downloads,watch}"
    echo
    echo "Verif VPN actif (IP de sortie = IP Proton) :"
    echo "  docker exec ${SERVICE_NAME}-vpn wget -qO- https://ipinfo.io/ip"
    echo
    echo "Verif port forwarded :"
    echo "  cat ${DATA_DIR}/gluetun/forwarded_port"
    echo "  docker logs ${SERVICE_NAME}-vpn 2>&1 | grep update-port"
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee. Data preservee dans DATA_DIR + DATA_PATH (rm -rf manuel pour purger)."
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
