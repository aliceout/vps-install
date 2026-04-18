#!/usr/bin/env bash
set -euo pipefail

# Aligne les records A Infomaniak sur l'IP publique du VPS.
# Auto-discovery des domaines depuis /etc/nginx/sites-enabled/*.conf,
# ou liste explicite en argument.
#
# Usage:
#   infomaniak-dns-sync                 # tous les server_name nginx
#   infomaniak-dns-sync foo.bar.fr ...  # domaines explicites
#
# Pre-requis:
#   - /etc/letsencrypt/infomaniak.ini avec dns_infomaniak_token=...
#   - jq, curl

LOG="/var/log/infomaniak-dns-sync.log"
CREDS="/etc/letsencrypt/infomaniak.ini"
API="https://api.infomaniak.com"
TTL=3600

log() {
  printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "$LOG" >&2
}

if [[ ! -s "$CREDS" ]]; then
  log "Creds Infomaniak manquants: $CREDS"
  exit 1
fi

TOKEN="$(grep -E '^dns_infomaniak_token' "$CREDS" | awk -F= '{print $2}' | tr -d ' ')"
if [[ -z "$TOKEN" || "$TOKEN" == "CHANGEME" ]]; then
  log "Token Infomaniak vide dans $CREDS"
  exit 1
fi

declare -a DOMAINS=()
if [[ $# -gt 0 ]]; then
  DOMAINS=("$@")
elif [[ -d /etc/nginx/sites-enabled ]]; then
  while IFS= read -r d; do
    [[ -n "$d" && "$d" != "_" ]] && DOMAINS+=("$d")
  done < <(
    grep -hE '^\s*server_name\s+' /etc/nginx/sites-enabled/*.conf 2>/dev/null \
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

api_call() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "$data" ]]; then
    curl -fsSL --max-time 15 \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -X "$method" --data "$data" "$API$path"
  else
    curl -fsSL --max-time 15 \
      -H "Authorization: Bearer $TOKEN" \
      -X "$method" "$API$path"
  fi
}

declare -A APEX_ID

find_domain_id() {
  local apex="$1"
  if [[ -n "${APEX_ID[$apex]:-}" ]]; then
    printf '%s' "${APEX_ID[$apex]}"
    return 0
  fi
  local resp id
  resp="$(api_call GET "/1/product?service_name=domain&customer_name=${apex}" 2>/dev/null || true)"
  id="$(printf '%s' "$resp" | jq -r --arg a "$apex" \
    'if type=="object" and has("data") then .data[] else .[] end
     | select(.customer_name==$a) | .id' 2>/dev/null | head -n1)"
  if [[ -z "$id" || "$id" == "null" ]]; then
    return 1
  fi
  APEX_ID[$apex]="$id"
  printf '%s' "$id"
}

# Resout apex Infomaniak et sous-domaine en testant les suffixes du plus long au plus court.
split_fqdn() {
  local fqdn="$1"
  local -a labels
  IFS='.' read -r -a labels <<< "$fqdn"
  local n=${#labels[@]}
  local i tail sub
  for ((i=0; i<n-1; i++)); do
    tail="$(IFS=.; echo "${labels[*]:$i}")"
    if find_domain_id "$tail" >/dev/null 2>&1; then
      if [[ $i -eq 0 ]]; then
        sub="@"
      else
        sub="$(IFS=.; echo "${labels[*]:0:$i}")"
      fi
      printf '%s|%s' "$sub" "$tail"
      return 0
    fi
  done
  return 1
}

sync_one() {
  local fqdn="$1"
  local pair sub apex domain_id records record_id current_target

  pair="$(split_fqdn "$fqdn" 2>/dev/null || true)"
  if [[ -z "$pair" ]]; then
    log "Aucun domaine Infomaniak trouve couvrant $fqdn, skip."
    return 0
  fi
  sub="${pair%|*}"
  apex="${pair#*|}"
  domain_id="$(find_domain_id "$apex")"

  records="$(api_call GET "/1/domain/$domain_id/dns/record" 2>/dev/null || true)"
  if [[ -z "$records" ]]; then
    log "GET records echoue pour $apex"
    return 1
  fi

  record_id="$(printf '%s' "$records" | jq -r --arg s "$sub" \
    'if type=="object" and has("data") then .data[] else .[] end
     | select(.source==$s and .type=="A") | .id' 2>/dev/null | head -n1)"
  current_target="$(printf '%s' "$records" | jq -r --arg s "$sub" \
    'if type=="object" and has("data") then .data[] else .[] end
     | select(.source==$s and .type=="A") | .target' 2>/dev/null | head -n1)"

  local payload
  payload="$(jq -n --arg s "$sub" --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{source:$s, target:$t, type:"A", ttl:$ttl}')"

  if [[ -z "$record_id" || "$record_id" == "null" ]]; then
    log "CREATE A $fqdn -> $PUBLIC_IP"
    api_call POST "/1/domain/$domain_id/dns/record" "$payload" >/dev/null
  elif [[ "$current_target" != "$PUBLIC_IP" ]]; then
    log "UPDATE A $fqdn $current_target -> $PUBLIC_IP"
    api_call PUT "/1/domain/$domain_id/dns/record/$record_id" "$payload" >/dev/null
  else
    log "OK     A $fqdn -> $PUBLIC_IP (a jour)"
  fi
}

rc=0
for d in "${DOMAINS[@]}"; do
  sync_one "$d" || { rc=1; log "Sync echouee pour $d"; }
done
exit "$rc"
