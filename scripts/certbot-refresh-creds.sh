#!/usr/bin/env bash
# Pre-hook appele par certbot renew (ou certbot-wildcard en direct) : recharge
# les fichiers ini de creds DNS depuis Infisical, pour que la rotation d'un
# token cote Infisical propage au prochain renouvellement.
#
# Lit /etc/certbot/providers.conf (format 'apex=provider:token_name' par ligne)
# pour savoir quelles creds fetcher. Ecrit :
#   /etc/certbot/creds/infomaniak/<name>.ini
#   /etc/certbot/creds/ovh/<name>.ini
#
# Sort toujours 0 : ne pas casser un renew si Infisical est HS, les ini
# existants devraient encore marcher sauf rotation recente.

set -uo pipefail

PROVIDERS_CONF="/etc/certbot/providers.conf"
CREDS_DIR="/etc/certbot/creds"

CLIENT_ID="$(cat /etc/infisical/client-id 2>/dev/null || true)"
CLIENT_SECRET="$(cat /etc/infisical/client-secret 2>/dev/null || true)"
PROJECT_ID="$(cat /etc/infisical/project-id 2>/dev/null || true)"
ENV_SLUG="$(cat /etc/infisical/environment 2>/dev/null || true)"

if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" || -z "$PROJECT_ID" || -z "$ENV_SLUG" ]]; then
  echo "Infisical config incomplete dans /etc/infisical/, skip refresh." >&2
  exit 0
fi

TOKEN="$(infisical login \
  --method=universal-auth \
  --client-id="$CLIENT_ID" --client-secret="$CLIENT_SECRET" \
  --plain --silent 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "Login Infisical echoue, skip refresh." >&2
  exit 0
fi

fetch() {
  local path="$1" key="$2"
  infisical secrets get "$key" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path="$path" \
    --token="$TOKEN" --plain 2>/dev/null || true
}

write_infomaniak() {
  local name="$1" token_value="$2"
  [[ -n "$token_value" ]] || return 0
  install -d -m 700 "$CREDS_DIR/infomaniak"
  umask 077
  cat > "$CREDS_DIR/infomaniak/${name}.ini" <<EOF
dns_infomaniak_token = ${token_value}
EOF
  chmod 600 "$CREDS_DIR/infomaniak/${name}.ini"
}

write_ovh() {
  local name="$1"
  local key_val secret_val consumer_val endpoint_val
  key_val="$(fetch "/vps/certbot/ovh/${name}" APPLICATION_KEY)"
  secret_val="$(fetch "/vps/certbot/ovh/${name}" APPLICATION_SECRET)"
  consumer_val="$(fetch "/vps/certbot/ovh/${name}" CONSUMER_KEY)"
  endpoint_val="$(fetch "/vps/certbot/ovh/${name}" ENDPOINT)"
  endpoint_val="${endpoint_val:-ovh-eu}"

  if [[ -z "$key_val" || -z "$secret_val" || -z "$consumer_val" ]]; then
    echo "Creds OVH incomplets sous /vps/certbot/ovh/${name}, skip." >&2
    return 0
  fi

  install -d -m 700 "$CREDS_DIR/ovh"
  umask 077
  cat > "$CREDS_DIR/ovh/${name}.ini" <<EOF
dns_ovh_endpoint = ${endpoint_val}
dns_ovh_application_key = ${key_val}
dns_ovh_application_secret = ${secret_val}
dns_ovh_consumer_key = ${consumer_val}
EOF
  chmod 600 "$CREDS_DIR/ovh/${name}.ini"
}

# Dedoublonne (provider, name) avant de fetch
declare -A seen
if [[ -f "$PROVIDERS_CONF" ]]; then
  while IFS='=' read -r apex rest; do
    apex="$(echo "$apex" | tr -d ' \t')"
    [[ -z "$apex" || "$apex" =~ ^# ]] && continue
    provider="$(echo "${rest%%:*}" | tr -d ' \t')"
    name="$(echo "${rest#*:}" | tr -d ' \t')"
    [[ -z "$provider" || -z "$name" ]] && continue

    key="${provider}/${name}"
    [[ -n "${seen[$key]:-}" ]] && continue
    seen[$key]=1

    case "$provider" in
      infomaniak)
        token_value="$(fetch "/vps/certbot/infomaniak" "$name")"
        write_infomaniak "$name" "$token_value"
        ;;
      ovh)
        write_ovh "$name"
        ;;
      *)
        echo "Provider inconnu '$provider' pour $apex, skip." >&2
        ;;
    esac
  done < "$PROVIDERS_CONF"
fi

exit 0
