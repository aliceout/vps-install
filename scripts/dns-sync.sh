#!/usr/bin/env bash
# Aligne les records A DNS sur l'IP publique du VPS.
# Multi-provider : lit /etc/certbot/providers.conf pour savoir quel
# token utiliser par apex.
#
# Pour l'instant le sync A record n'est implemente que pour Infomaniak.
# Les domaines dont l'apex est chez OVH sont skippes (log WARN).
#
# Usage:
#   dns-sync                      # auto-discover depuis /etc/nginx/conf/*.conf
#   dns-sync foo.bar.fr ...       # liste explicite
#
# Pre-requis:
#   - /etc/certbot/creds/infomaniak/<name>.ini (genere par certbot-refresh-creds)
#   - jq, curl

set -uo pipefail

LOG="/var/log/dns-sync.log"
PROVIDERS_CONF="/etc/certbot/providers.conf"
CREDS_DIR="/etc/certbot/creds"
API_INFOMANIAK="https://api.infomaniak.com"
TTL=3600

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2
}

# Map apex -> (provider, token_name)
declare -A APEX_PROVIDER
declare -A APEX_TOKEN_NAME

load_providers_conf() {
  [[ -f "$PROVIDERS_CONF" ]] || return 0
  while IFS='=' read -r apex rest; do
    apex="$(echo "$apex" | tr -d ' \t')"
    [[ -z "$apex" || "$apex" =~ ^# ]] && continue
    local prov="${rest%%:*}" name="${rest#*:}"
    prov="$(echo "$prov" | tr -d ' \t')"
    name="$(echo "$name" | tr -d ' \t')"
    [[ -z "$prov" || -z "$name" ]] && continue
    APEX_PROVIDER[$apex]="$prov"
    APEX_TOKEN_NAME[$apex]="$name"
  done < "$PROVIDERS_CONF"
}

load_providers_conf

# Retourne le token Infomaniak pour un apex. Echoue si l'apex n'est pas
# declare dans providers.conf avec provider=infomaniak.
infomaniak_token_for_apex() {
  local apex="$1" name ini
  [[ "${APEX_PROVIDER[$apex]:-}" == "infomaniak" ]] || return 1
  name="${APEX_TOKEN_NAME[$apex]:-}"
  [[ -n "$name" ]] || return 1
  ini="$CREDS_DIR/infomaniak/${name}.ini"
  [[ -s "$ini" ]] || return 1
  grep -E '^dns_infomaniak_token' "$ini" | awk -F= '{print $2}' | tr -d ' '
}

declare -a DOMAINS=()
if [[ $# -gt 0 ]]; then
  DOMAINS=("$@")
elif [[ -d /etc/nginx/conf ]]; then
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "_" ]] && DOMAINS+=("$d")
  done < <(
    grep -hE '^\s*server_name\s+' /etc/nginx/conf/*.conf 2>/dev/null \
      | sed -E 's/^\s*server_name\s+//; s/;.*$//' \
      | tr ' ' '\n' \
      | sed '/^$/d' \
      | sort -u
  )
fi

if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  log "Aucun domaine a synchroniser."
  exit 0
fi

PUBLIC_IP="$(curl -fsS4 --max-time 5 https://api.ipify.org 2>/dev/null \
  || curl -fsS4 --max-time 5 https://ifconfig.me 2>/dev/null \
  || true)"
if [[ -z "$PUBLIC_IP" ]]; then
  log "Impossible de recuperer l'IP publique."
  exit 1
fi
log "IP publique: $PUBLIC_IP"

# ---- Infomaniak API helpers -------------------------------------------------

api_call_infomaniak() {
  local token="$1" method="$2" path="$3" data="${4:-}"
  if [[ -n "$data" ]]; then
    curl -fsSL --max-time 15 \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -X "$method" --data "$data" "$API_INFOMANIAK$path"
  else
    curl -fsSL --max-time 15 \
      -H "Authorization: Bearer $token" \
      -X "$method" "$API_INFOMANIAK$path"
  fi
}

declare -A APEX_ID

find_domain_id_infomaniak() {
  local token="$1" apex="$2"
  if [[ -n "${APEX_ID[$apex]:-}" ]]; then
    printf '%s' "${APEX_ID[$apex]}"
    return 0
  fi
  local resp id
  resp="$(api_call_infomaniak "$token" GET "/1/product?service_name=domain&customer_name=${apex}" 2>/dev/null || true)"
  id="$(printf '%s' "$resp" | jq -r --arg a "$apex" \
    'if type=="object" and has("data") then .data[] else .[] end
     | select(.customer_name==$a) | .id' 2>/dev/null | head -n1)"
  if [[ -z "$id" || "$id" == "null" ]]; then
    return 1
  fi
  APEX_ID[$apex]="$id"
  printf '%s' "$id"
}

# Teste les suffixes du plus long au plus court pour trouver l'apex.
# Utilise Infomaniak par defaut (fallback legacy). Si l'apex n'est pas
# Infomaniak (pas dans providers.conf ou provider=ovh), retourne echec.
split_fqdn_infomaniak() {
  local token="$1" fqdn="$2"
  local -a labels
  IFS='.' read -r -a labels <<< "$fqdn"
  local n=${#labels[@]}
  local i tail sub
  for ((i=0; i<n-1; i++)); do
    tail="$(IFS=.; echo "${labels[*]:$i}")"
    if find_domain_id_infomaniak "$token" "$tail" >/dev/null 2>&1; then
      if [[ $i -eq 0 ]]; then sub="@"; else sub="$(IFS=.; echo "${labels[*]:0:$i}")"; fi
      printf '%s|%s' "$sub" "$tail"
      return 0
    fi
  done
  return 1
}

sync_one_infomaniak() {
  local token="$1" fqdn="$2"
  local pair sub apex domain_id records record_id current_target

  pair="$(split_fqdn_infomaniak "$token" "$fqdn" 2>/dev/null || true)"
  if [[ -z "$pair" ]]; then
    log "Aucun domaine Infomaniak trouve couvrant $fqdn, skip."
    return 0
  fi
  sub="${pair%|*}"
  apex="${pair#*|}"
  domain_id="$(find_domain_id_infomaniak "$token" "$apex")"

  records="$(api_call_infomaniak "$token" GET "/1/domain/$domain_id/dns/record" 2>/dev/null || true)"
  if [[ -z "$records" ]]; then
    log "GET records echoue pour $apex"
    return 1
  fi

  record_id="$(printf '%s' "$records" | jq -r --arg s "$sub" '
    if type=="object" and has("data") then .data[] else .[] end
    | select(.type=="A" and (
        .source==$s
        or ($s=="@" and (.source=="." or .source=="" or .source==null))
      )) | .id' 2>/dev/null | head -n1)"
  current_target="$(printf '%s' "$records" | jq -r --arg s "$sub" '
    if type=="object" and has("data") then .data[] else .[] end
    | select(.type=="A" and (
        .source==$s
        or ($s=="@" and (.source=="." or .source=="" or .source==null))
      )) | .target' 2>/dev/null | head -n1)"

  local create_payload update_payload
  create_payload="$(jq -n --arg s "$sub" --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{source:$s, target:$t, type:"A", ttl:$ttl}')"
  update_payload="$(jq -n --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{target:$t, ttl:$ttl}')"

  if [[ -z "$record_id" || "$record_id" == "null" ]]; then
    log "CREATE A $fqdn -> $PUBLIC_IP"
    api_call_infomaniak "$token" POST "/1/domain/$domain_id/dns/record" "$create_payload" >/dev/null
  elif [[ "$current_target" != "$PUBLIC_IP" ]]; then
    log "UPDATE A $fqdn $current_target -> $PUBLIC_IP"
    if [[ "$sub" == "@" ]]; then
      # Apex: PUT renvoie 500 chez Infomaniak. Workaround DELETE + CREATE.
      api_call_infomaniak "$token" DELETE "/1/domain/$domain_id/dns/record/$record_id" >/dev/null \
        && sleep 1 \
        && api_call_infomaniak "$token" POST "/1/domain/$domain_id/dns/record" "$create_payload" >/dev/null
    else
      api_call_infomaniak "$token" PUT "/1/domain/$domain_id/dns/record/$record_id" "$update_payload" >/dev/null
    fi
  else
    log "OK     A $fqdn -> $PUBLIC_IP (a jour)"
  fi
}

# Retourne l'apex candidat (dernier 2 labels) sans verifier l'ownership.
guess_apex() {
  local fqdn="$1"
  local -a labels
  IFS='.' read -r -a labels <<< "$fqdn"
  local n=${#labels[@]}
  if (( n < 2 )); then echo "$fqdn"; return; fi
  echo "${labels[n-2]}.${labels[n-1]}"
}

# ---- Dispatch par provider --------------------------------------------------

rc=0
for d in "${DOMAINS[@]}"; do
  apex="$(guess_apex "$d")"
  provider="${APEX_PROVIDER[$apex]:-}"

  if [[ "$provider" == "ovh" ]]; then
    log "SKIP   A $d (apex $apex chez OVH, sync non implementee)"
    continue
  fi

  # infomaniak explicite OU fallback legacy
  token="$(infomaniak_token_for_apex "$apex" 2>/dev/null || true)"
  if [[ -z "$token" || "$token" == "CHANGEME" ]]; then
    log "SKIP   A $d (pas de token Infomaniak utilisable pour $apex)"
    continue
  fi
  sync_one_infomaniak "$token" "$d" || { rc=1; log "Sync A echouee pour $d"; }
done
exit "$rc"
