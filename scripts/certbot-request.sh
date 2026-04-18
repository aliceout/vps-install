#!/usr/bin/env bash
set -euo pipefail

# Requête un cert Let's Encrypt (DNS Infomaniak) pour un domaine unique.
# Usage: certbot-request <domain> [<domain>...]

CREDENTIALS="/etc/letsencrypt/infomaniak.ini"
EMAIL_FILE="/etc/letsencrypt/email"
CERTBOT_BIN="$(command -v certbot || true)"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <domain> [<domain>...]"
  exit 1
fi

if [[ -z "$CERTBOT_BIN" ]]; then
  echo "certbot introuvable" >&2
  exit 1
fi

if [[ ! -s "$CREDENTIALS" ]]; then
  echo "Credentials manquants: $CREDENTIALS" >&2
  exit 1
fi

TOKEN_VALUE="$(grep -E '^dns_infomaniak_token' "$CREDENTIALS" | awk -F= '{print $2}' | tr -d ' ')"
if [[ -z "$TOKEN_VALUE" || "$TOKEN_VALUE" == "CHANGEME" ]]; then
  echo "Token Infomaniak vide dans $CREDENTIALS" >&2
  exit 1
fi

EMAIL=""
if [[ -s "$EMAIL_FILE" ]]; then
  EMAIL="$(head -n1 "$EMAIL_FILE" | tr -d ' \t\r\n')"
fi
if [[ -z "$EMAIL" ]]; then
  echo "Email manquant dans $EMAIL_FILE" >&2
  exit 1
fi

for DOMAIN in "$@"; do
  LIVE_DIR="/etc/letsencrypt/live/${DOMAIN}"
  if [[ -f "${LIVE_DIR}/fullchain.pem" ]]; then
    echo "Cert deja present pour ${DOMAIN}, skip."
    continue
  fi

  echo "Requete cert pour ${DOMAIN}..."
  "$CERTBOT_BIN" certonly \
    --authenticator dns-infomaniak \
    --dns-infomaniak-credentials "$CREDENTIALS" \
    --dns-infomaniak-propagation-seconds 180 \
    -d "$DOMAIN" \
    --preferred-challenges dns \
    --agree-tos --non-interactive \
    --email "$EMAIL" \
    --keep-until-expiring
done
