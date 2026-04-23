#!/usr/bin/env bash
# Requete un cert Let's Encrypt wildcard (*.apex + apex) pour un apex donne,
# en utilisant le plugin DNS du provider choisi.
#
# Usage:
#   certbot-wildcard <apex> <provider> <token_name>
#   ex: certbot-wildcard alice.fr ovh client1
#       certbot-wildcard backlice.dev infomaniak perso
#
# Credentials attendus (regeneres par certbot-refresh-creds, pre-hook de
# certbot.timer) :
#   /etc/certbot/creds/<provider>/<name>.ini
#
# Met a jour /etc/certbot/providers.conf (map apex -> provider:name) pour
# que les renouvellements automatiques sachent refresh les bonnes creds.

set -euo pipefail

APEX="${1:-}"
PROVIDER="${2:-}"
TOKEN_NAME="${3:-}"

if [[ -z "$APEX" || -z "$PROVIDER" || -z "$TOKEN_NAME" ]]; then
  echo "Usage: $0 <apex> <provider> <token_name>" >&2
  exit 1
fi

EMAIL_FILE="/etc/letsencrypt/email"
DOMAINS_FILE="/etc/letsencrypt/domains.ini"
PROVIDERS_CONF="/etc/certbot/providers.conf"
CREDS_DIR="/etc/certbot/creds"
REFRESH_BIN="/usr/local/sbin/certbot-refresh-creds"

CERTBOT_BIN="/usr/local/bin/certbot"
[[ -x "$CERTBOT_BIN" ]] || CERTBOT_BIN="$(command -v certbot || true)"
[[ -n "$CERTBOT_BIN" ]] || { echo "certbot introuvable" >&2; exit 1; }

LIVE_DIR="/etc/letsencrypt/live/${APEX}"
NGINX_CERT_INCLUDE="/etc/nginx/certificat/${APEX}.conf"

write_nginx_cert_include() {
  install -d -m 755 /etc/nginx/certificat
  cat > "$NGINX_CERT_INCLUDE" <<EOF
ssl_certificate     /etc/letsencrypt/live/${APEX}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${APEX}/privkey.pem;
ssl_trusted_certificate /etc/letsencrypt/live/${APEX}/chain.pem;
EOF
  chmod 644 "$NGINX_CERT_INCLUDE"
}

# Ajoute/update la ligne apex=provider:name dans /etc/certbot/providers.conf
update_providers_conf() {
  local apex="$1" provider="$2" name="$3"
  install -d -m 755 /etc/certbot
  touch "$PROVIDERS_CONF"
  local tmp
  tmp="$(mktemp)"
  grep -vE "^${apex}=" "$PROVIDERS_CONF" > "$tmp" || true
  printf '%s=%s:%s\n' "$apex" "$provider" "$name" >> "$tmp"
  mv "$tmp" "$PROVIDERS_CONF"
  chmod 644 "$PROVIDERS_CONF"
}

case "$PROVIDER" in
  infomaniak) CREDS="$CREDS_DIR/infomaniak/${TOKEN_NAME}.ini" ;;
  ovh)        CREDS="$CREDS_DIR/ovh/${TOKEN_NAME}.ini" ;;
  *) echo "Provider inconnu: $PROVIDER (attendu: infomaniak|ovh)" >&2; exit 1 ;;
esac
update_providers_conf "$APEX" "$PROVIDER" "$TOKEN_NAME"
[[ -x "$REFRESH_BIN" ]] && "$REFRESH_BIN" >/dev/null 2>&1 || true

if [[ ! -s "$CREDS" ]]; then
  echo "Credentials manquants: $CREDS" >&2
  echo "Verifie l'entree dans Infisical et que certbot-refresh-creds a tourne sans erreur." >&2
  exit 1
fi

EMAIL=""
if [[ -s "$EMAIL_FILE" ]]; then
  EMAIL="$(head -n1 "$EMAIL_FILE" | tr -d ' \t\r\n')"
fi
[[ -n "$EMAIL" ]] || { echo "Email manquant dans $EMAIL_FILE" >&2; exit 1; }

# Ajoute l'apex a domains.ini (renouvellement en bulk)
if [[ -f "$DOMAINS_FILE" ]] && ! grep -qxF "$APEX" "$DOMAINS_FILE"; then
  printf '%s\n' "$APEX" >> "$DOMAINS_FILE"
fi

if [[ -f "${LIVE_DIR}/fullchain.pem" ]]; then
  echo "Cert wildcard deja present pour ${APEX}, skip."
  write_nginx_cert_include
  exit 0
fi

echo "Requete cert wildcard pour ${APEX} et *.${APEX} via provider=${PROVIDER}"
echo "(propagation DNS ~3 min)"

case "$PROVIDER" in
  infomaniak)
    "$CERTBOT_BIN" certonly \
      --authenticator dns-infomaniak \
      --dns-infomaniak-credentials "$CREDS" \
      --dns-infomaniak-propagation-seconds 180 \
      -d "$APEX" -d "*.${APEX}" \
      --preferred-challenges dns \
      --agree-tos --non-interactive \
      --email "$EMAIL" \
      --keep-until-expiring --expand
    ;;
  ovh)
    "$CERTBOT_BIN" certonly \
      --authenticator dns-ovh \
      --dns-ovh-credentials "$CREDS" \
      --dns-ovh-propagation-seconds 120 \
      -d "$APEX" -d "*.${APEX}" \
      --preferred-challenges dns \
      --agree-tos --non-interactive \
      --email "$EMAIL" \
      --keep-until-expiring --expand
    ;;
esac

write_nginx_cert_include
