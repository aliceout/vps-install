#!/usr/bin/env bash
# Aligne les records A DNS sur l'IP publique du VPS.
# Multi-provider : lit /etc/certbot/providers.conf pour savoir quel
# token utiliser par apex.
#
# Sync A record implemente pour Infomaniak, OVH ET Spaceship. Le provider par
# apex est lu dans /etc/certbot/providers.conf. OVH utilise l'API a requetes
# signees (X-Ovh-Signature) ; Spaceship une API a cles (X-Api-Key /
# X-Api-Secret). Dans les deux cas les creds viennent du meme ini que certbot.
#
# Usage:
#   dns-sync                      # auto-discover depuis /etc/nginx/conf/*.conf
#   dns-sync foo.bar.fr ...       # liste explicite
#
# Pre-requis:
#   - /etc/certbot/creds/<provider>/<name>.ini (genere par certbot-refresh-creds)
#   - jq, curl, openssl (ou sha1sum)

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

# ---- OVH API helpers --------------------------------------------------------
# OVH exige des requetes signees. On charge les creds depuis le meme ini que
# certbot (/etc/certbot/creds/ovh/<name>.ini) puis on signe chaque appel :
#   X-Ovh-Signature = "$1$" + sha1(AS+"+"+CK+"+"+METHOD+"+"+URL+"+"+BODY+"+"+TS)
# Le timestamp doit etre aligne sur l'horloge OVH -> on calcule un offset via
# /auth/time (non signe) au chargement des creds.

OVH_AK=""; OVH_AS=""; OVH_CK=""; OVH_BASE=""; OVH_TIME_OFFSET=0

sha1_hex() {
  if command -v sha1sum >/dev/null 2>&1; then
    sha1sum | awk '{print $1}'
  else
    openssl sha1 2>/dev/null | awk '{print $NF}'
  fi
}

load_ovh_creds() {
  local name="$1" ini="$CREDS_DIR/ovh/${name}.ini" ep=""
  [[ -s "$ini" ]] || { log "creds OVH absents: $ini"; return 1; }
  OVH_AK="$(awk -F= '/^dns_ovh_application_key/{print $2; exit}'    "$ini" | tr -d ' \t\r')"
  OVH_AS="$(awk -F= '/^dns_ovh_application_secret/{print $2; exit}' "$ini" | tr -d ' \t\r')"
  OVH_CK="$(awk -F= '/^dns_ovh_consumer_key/{print $2; exit}'       "$ini" | tr -d ' \t\r')"
  ep="$(awk -F= '/^dns_ovh_endpoint/{print $2; exit}'              "$ini" | tr -d ' \t\r')"
  case "$ep" in
    ovh-ca) OVH_BASE="https://ca.api.ovh.com/1.0" ;;
    ovh-us) OVH_BASE="https://api.us.ovhcloud.com/1.0" ;;
    ovh-eu|"") OVH_BASE="https://eu.api.ovh.com/1.0" ;;
    *) OVH_BASE="https://eu.api.ovh.com/1.0" ;;
  esac
  [[ -n "$OVH_AK" && -n "$OVH_AS" && -n "$OVH_CK" ]] || { log "creds OVH incomplets: $ini"; return 1; }

  local srv
  srv="$(curl -fsS --max-time 10 "${OVH_BASE}/auth/time" 2>/dev/null || true)"
  if [[ "$srv" =~ ^[0-9]+$ ]]; then
    OVH_TIME_OFFSET=$(( srv - $(date +%s) ))
  else
    OVH_TIME_OFFSET=0
  fi
}

ovh_api() {
  local method="$1" path="$2" body="${3:-}"
  local url="${OVH_BASE}${path}" ts sig
  ts=$(( $(date +%s) + OVH_TIME_OFFSET ))
  sig="\$1\$$(printf '%s' "${OVH_AS}+${OVH_CK}+${method}+${url}+${body}+${ts}" | sha1_hex)"
  local -a args=( -fsSL --max-time 15 -X "$method"
    -H "X-Ovh-Application: $OVH_AK"
    -H "X-Ovh-Consumer: $OVH_CK"
    -H "X-Ovh-Timestamp: $ts"
    -H "X-Ovh-Signature: $sig" )
  if [[ -n "$body" ]]; then
    args+=( -H "Content-Type: application/json" --data "$body" )
  fi
  curl "${args[@]}" "$url"
}

sync_one_ovh() {
  local apex="$1" fqdn="$2" name="$3"
  load_ovh_creds "$name" || return 1

  # subDomain OVH = partie avant l'apex ("" pour l'apex lui-meme)
  local sub
  if [[ "$fqdn" == "$apex" ]]; then sub=""; else sub="${fqdn%.$apex}"; fi

  local ids id
  ids="$(ovh_api GET "/domain/zone/${apex}/record?fieldType=A&subDomain=${sub}" 2>/dev/null || true)"
  id="$(printf '%s' "$ids" | jq -r 'if type=="array" then .[0] else empty end' 2>/dev/null)"

  local create_body update_body
  create_body="$(jq -n --arg s "$sub" --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{fieldType:"A", subDomain:$s, target:$t, ttl:$ttl}')"
  update_body="$(jq -n --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{target:$t, ttl:$ttl}')"

  local changed=0
  if [[ -z "$id" || "$id" == "null" ]]; then
    log "CREATE A $fqdn -> $PUBLIC_IP (OVH)"
    ovh_api POST "/domain/zone/${apex}/record" "$create_body" >/dev/null || { log "CREATE KO $fqdn (OVH)"; return 1; }
    changed=1
  else
    local current
    current="$(ovh_api GET "/domain/zone/${apex}/record/${id}" 2>/dev/null | jq -r '.target' 2>/dev/null || true)"
    if [[ "$current" != "$PUBLIC_IP" ]]; then
      log "UPDATE A $fqdn $current -> $PUBLIC_IP (OVH)"
      ovh_api PUT "/domain/zone/${apex}/record/${id}" "$update_body" >/dev/null || { log "UPDATE KO $fqdn (OVH)"; return 1; }
      changed=1
    else
      log "OK     A $fqdn -> $PUBLIC_IP (OVH, a jour)"
    fi
  fi

  # OVH n'applique les changements de zone qu'apres un refresh explicite.
  if (( changed )); then
    ovh_api POST "/domain/zone/${apex}/refresh" "" >/dev/null 2>&1 || log "WARN refresh zone $apex KO (OVH)"
  fi
}

# ---- Spaceship API helpers --------------------------------------------------
# Spaceship expose une API a cles (pas de signature) : deux headers
#   X-Api-Key / X-Api-Secret
# Les creds viennent du meme ini que certbot (le plugin certbot-dns-spaceship
# lit ce fichier au format [spaceship] api_key/api_secret) :
#   /etc/certbot/creds/spaceship/<name>.ini
# Le champ IP d'un record A s'appelle "address" (PAS "value"), le "name" est
# RELATIF a l'apex ("" pour l'apex lui-meme). L'ecriture se fait par upsert :
#   PUT /dns/records/<apex>  body {force:true, items:[{type,name,address,ttl}]}
# force:true ecrase le record A de meme (name,type) et LAISSE le reste de la
# zone intact (ce n'est PAS un remplacement complet de zone).

SPACESHIP_BASE="https://spaceship.dev/api/v1"
SPACESHIP_KEY=""; SPACESHIP_SECRET=""

load_spaceship_creds() {
  local name="$1" ini="$CREDS_DIR/spaceship/${name}.ini"
  [[ -s "$ini" ]] || { log "creds Spaceship absents: $ini"; return 1; }
  # Format ini du plugin certbot : section [spaceship], cles api_key/api_secret.
  # On tolere espaces autour du '=' ; on retire tout ce qui precede le 1er '='.
  SPACESHIP_KEY="$(awk -F= '/^[[:space:]]*api_key[[:space:]]*=/{sub(/^[^=]*=/,""); gsub(/[[:space:]]/,""); print; exit}'    "$ini")"
  SPACESHIP_SECRET="$(awk -F= '/^[[:space:]]*api_secret[[:space:]]*=/{sub(/^[^=]*=/,""); gsub(/[[:space:]]/,""); print; exit}' "$ini")"
  [[ -n "$SPACESHIP_KEY" && -n "$SPACESHIP_SECRET" ]] || { log "creds Spaceship incomplets: $ini"; return 1; }
}

spaceship_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=( -fsSL --max-time 15 -X "$method"
    -H "X-Api-Key: $SPACESHIP_KEY"
    -H "X-Api-Secret: $SPACESHIP_SECRET"
    -H "Accept: application/json" )
  if [[ -n "$body" ]]; then
    args+=( -H "Content-Type: application/json" --data "$body" )
  fi
  curl "${args[@]}" "${SPACESHIP_BASE}${path}"
}

sync_one_spaceship() {
  local apex="$1" fqdn="$2" name="$3"
  load_spaceship_creds "$name" || return 1

  # name Spaceship = relatif a l'apex : "" pour l'apex, sinon le prefixe.
  local sub
  if [[ "$fqdn" == "$apex" ]]; then sub=""; else sub="${fqdn%.$apex}"; fi

  # Liste les records de la zone et cherche le A de notre sous-domaine.
  # On matche large sur l'apex (""/"@"/".") pour couvrir toutes les
  # representations possibles cote API.
  local list current
  list="$(spaceship_api GET "/dns/records/${apex}?take=500&skip=0" 2>/dev/null || true)"
  current="$(printf '%s' "$list" | jq -r --arg s "$sub" '
    (.items // [])
    | map(select(.type=="A" and (
        .name==$s or ($s=="" and (.name=="@" or .name=="."))
      )))
    | (.[0].address // empty)' 2>/dev/null || true)"

  if [[ "$current" == "$PUBLIC_IP" ]]; then
    log "OK     A $fqdn -> $PUBLIC_IP (Spaceship, a jour)"
    return 0
  fi

  local body
  body="$(jq -n --arg s "$sub" --arg t "$PUBLIC_IP" --argjson ttl "$TTL" \
    '{force:true, items:[{type:"A", name:$s, address:$t, ttl:$ttl}]}')"

  if [[ -z "$current" ]]; then
    log "CREATE A $fqdn -> $PUBLIC_IP (Spaceship)"
  else
    log "UPDATE A $fqdn $current -> $PUBLIC_IP (Spaceship)"
  fi
  spaceship_api PUT "/dns/records/${apex}" "$body" >/dev/null \
    || { log "WRITE KO $fqdn (Spaceship)"; return 1; }
}

# ---- Dispatch par provider --------------------------------------------------

rc=0
for d in "${DOMAINS[@]}"; do
  apex="$(guess_apex "$d")"
  provider="${APEX_PROVIDER[$apex]:-}"

  if [[ "$provider" == "ovh" ]]; then
    name="${APEX_TOKEN_NAME[$apex]:-}"
    if [[ -z "$name" ]]; then
      log "SKIP   A $d (apex $apex chez OVH mais pas de token dans providers.conf)"
      continue
    fi
    sync_one_ovh "$apex" "$d" "$name" || { rc=1; log "Sync A OVH echouee pour $d"; }
    continue
  fi

  if [[ "$provider" == "spaceship" ]]; then
    name="${APEX_TOKEN_NAME[$apex]:-}"
    if [[ -z "$name" ]]; then
      log "SKIP   A $d (apex $apex chez Spaceship mais pas de token dans providers.conf)"
      continue
    fi
    sync_one_spaceship "$apex" "$d" "$name" || { rc=1; log "Sync A Spaceship echouee pour $d"; }
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
