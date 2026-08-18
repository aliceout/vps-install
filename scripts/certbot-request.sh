#!/usr/bin/env bash
# Requete un cert Let's Encrypt pour un ou plusieurs domaines (non wildcard),
# en utilisant le plugin DNS du provider choisi.
#
# Usage:
#   certbot-request --provider <p> --token <name> <domain> [<domain>...]
#   ex: certbot-request --provider ovh --token client1 bar.alice.fr

set -euo pipefail

PROVIDER=""
TOKEN_NAME=""
DOMAINS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --token)    TOKEN_NAME="$2"; shift 2 ;;
    -h|--help)  sed -n '2,10p' "$0"; exit 0 ;;
    *)          DOMAINS+=("$1"); shift ;;
  esac
done

if [[ -z "$PROVIDER" || -z "$TOKEN_NAME" || ${#DOMAINS[@]} -eq 0 ]]; then
  echo "Usage: $0 --provider <p> --token <n> <domain> [<domain>...]" >&2
  exit 1
fi

EMAIL_FILE="/etc/letsencrypt/email"
CREDS_DIR="/etc/certbot/creds"
REFRESH_BIN="/usr/local/sbin/certbot-refresh-creds"

CERTBOT_BIN="/usr/local/bin/certbot"
[[ -x "$CERTBOT_BIN" ]] || CERTBOT_BIN="$(command -v certbot || true)"
[[ -n "$CERTBOT_BIN" ]] || { echo "certbot introuvable" >&2; exit 1; }

case "$PROVIDER" in
  infomaniak) CREDS="$CREDS_DIR/infomaniak/${TOKEN_NAME}.ini" ;;
  ovh)        CREDS="$CREDS_DIR/ovh/${TOKEN_NAME}.ini" ;;
  spaceship)  CREDS="$CREDS_DIR/spaceship/${TOKEN_NAME}.ini" ;;
  *) echo "Provider inconnu: $PROVIDER (attendu: infomaniak|ovh|spaceship)" >&2; exit 1 ;;
esac
[[ -x "$REFRESH_BIN" ]] && "$REFRESH_BIN" >/dev/null 2>&1 || true

[[ -s "$CREDS" ]] || { echo "Credentials manquants: $CREDS" >&2; exit 1; }

EMAIL=""
[[ -s "$EMAIL_FILE" ]] && EMAIL="$(head -n1 "$EMAIL_FILE" | tr -d ' \t\r\n')"
[[ -n "$EMAIL" ]] || { echo "Email manquant dans $EMAIL_FILE" >&2; exit 1; }

for DOMAIN in "${DOMAINS[@]}"; do
  LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
  if [[ -f "${LIVE_DIR}/fullchain.pem" ]]; then
    echo "Cert deja present pour ${DOMAIN}, skip."
    continue
  fi

  echo "Requete cert pour ${DOMAIN} (provider=${PROVIDER})..."
  case "$PROVIDER" in
    infomaniak)
      "$CERTBOT_BIN" certonly \
        --authenticator dns-infomaniak \
        --dns-infomaniak-credentials "$CREDS" \
        --dns-infomaniak-propagation-seconds 180 \
        -d "$DOMAIN" \
        --preferred-challenges dns \
        --agree-tos --non-interactive \
        --email "$EMAIL" \
        --keep-until-expiring
      ;;
    ovh)
      "$CERTBOT_BIN" certonly \
        --authenticator dns-ovh \
        --dns-ovh-credentials "$CREDS" \
        --dns-ovh-propagation-seconds 120 \
        -d "$DOMAIN" \
        --preferred-challenges dns \
        --agree-tos --non-interactive \
        --email "$EMAIL" \
        --keep-until-expiring
      ;;
    spaceship)
      # --dns-spaceship-propagation-seconds n'est passe que s'il est reconnu
      # par le plugin (voir certbot-wildcard.sh pour le detail).
      prop=()
      if "$CERTBOT_BIN" --help dns-spaceship 2>/dev/null | grep -q -- '--dns-spaceship-propagation-seconds'; then
        prop=(--dns-spaceship-propagation-seconds 120)
      fi
      "$CERTBOT_BIN" certonly \
        --authenticator dns-spaceship \
        --dns-spaceship-credentials "$CREDS" \
        "${prop[@]}" \
        -d "$DOMAIN" \
        --preferred-challenges dns \
        --agree-tos --non-interactive \
        --email "$EMAIL" \
        --keep-until-expiring
      ;;
  esac
done
