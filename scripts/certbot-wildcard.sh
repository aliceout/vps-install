#!/usr/bin/env bash
set -euo pipefail

# Requete un cert Let's Encrypt wildcard (DNS Infomaniak) pour un apex.
# Le cert couvre apex + *.apex, stocke dans /etc/letsencrypt/live/<apex>/.
# Idempotent: skip si le cert existe deja.
#
# Usage: certbot-wildcard <apex>

APEX="${1:-}"
if [[ -z "$APEX" ]]; then
  echo "Usage: $0 <apex>" >&2
  exit 1
fi

CREDENTIALS="/etc/letsencrypt/infomaniak.ini"
EMAIL_FILE="/etc/letsencrypt/email"
DOMAINS_FILE="/etc/letsencrypt/domains.ini"
CERTBOT_BIN="$(command -v certbot || true)"
LIVE_DIR="/etc/letsencrypt/live/${APEX}"

if [[ -z "$CERTBOT_BIN" ]]; then
  echo "certbot introuvable" >&2
  exit 1
fi

if [[ ! -s "$CREDENTIALS" ]]; then
  echo "Credentials Infomaniak manquants: $CREDENTIALS" >&2
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

# Ajoute l'apex a domains.ini (auto-renouvellement wildcard via certbot-dns)
if [[ -f "$DOMAINS_FILE" ]] && ! grep -qxF "$APEX" "$DOMAINS_FILE"; then
  printf '%s\n' "$APEX" >> "$DOMAINS_FILE"
fi

if [[ -f "${LIVE_DIR}/fullchain.pem" ]]; then
  echo "Cert wildcard deja present pour ${APEX}, skip."
  exit 0
fi

echo "Requete cert wildcard pour ${APEX} et *.${APEX}..."
"$CERTBOT_BIN" certonly \
  --authenticator dns-infomaniak \
  --dns-infomaniak-credentials "$CREDENTIALS" \
  --dns-infomaniak-propagation-seconds 180 \
  -d "$APEX" -d "*.${APEX}" \
  --preferred-challenges dns \
  --agree-tos --non-interactive \
  --email "$EMAIL" \
  --keep-until-expiring --expand
