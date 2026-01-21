#!/usr/bin/env bash
set -euo pipefail

CREDENTIALS="/etc/letsencrypt/infomaniak.ini"
EMAIL="certbot.swan624@slmail.me"
CERTBOT_BIN="/usr/local/bin/certbot"
if [[ ! -x "$CERTBOT_BIN" ]]; then
  CERTBOT_BIN="$(command -v certbot || true)"
fi
if [[ -z "${CERTBOT_BIN:-}" ]]; then
  echo "certbot introuvable"
  exit 1
fi

if [[ ! -f "$CREDENTIALS" ]]; then
  echo "Fichier credentials manquant: $CREDENTIALS"
  exit 1
fi
TOKEN_VALUE="$(grep -E '^dns_infomaniak_token' "$CREDENTIALS" | awk -F= '{print $2}' | tr -d ' ')"
if [[ -z "$TOKEN_VALUE" || "$TOKEN_VALUE" == "CHANGEME" ]]; then
  echo "Token Infomaniak manquant dans $CREDENTIALS"
  exit 1
fi

DOMAINS_FILE="/etc/letsencrypt/domains.ini"
if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "Fichier domains manquant: $DOMAINS_FILE"
  exit 1
fi

mapfile -t DOMAINS < <(grep -Ev '^\s*(#|$)' "$DOMAINS_FILE")
if [[ ${#DOMAINS[@]} -eq 0 ]]; then
  echo "Aucun domaine dans $DOMAINS_FILE"
  exit 1
fi

LOG_DIR="/var/log/cron"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/certbot-dns-$(date +%F).log"

OK_LIST=()
ERR_LIST=()

log(){ echo "$1" | tee -a "$LOG_FILE"; }

log ""
log "Start $(date)"
log "------------------------------------------"
log ""

for DOMAIN in "${DOMAINS[@]}"; do
  log "Domain: $DOMAIN"

  set +e
  sudo "$CERTBOT_BIN" certonly \
    -vv \
    --authenticator dns-infomaniak \
    --dns-infomaniak-credentials "$CREDENTIALS" \
    --dns-infomaniak-propagation-seconds 180 \
    -d "$DOMAIN" -d "*.$DOMAIN" \
    --preferred-challenges dns \
    --agree-tos --non-interactive \
    --email "$EMAIL" \
    --keep-until-expiring --expand 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e

  if [ $rc -eq 0 ]; then
    log "OK: $DOMAIN"
    OK_LIST+=("$DOMAIN")
  else
    log "FAILED: $DOMAIN (exit $rc)"
    [ -f /var/log/letsencrypt/letsencrypt.log ] && {
      log "-- tail /var/log/letsencrypt/letsencrypt.log --"
      tail -n 80 /var/log/letsencrypt/letsencrypt.log | sed 's/^/    /' | tee -a "$LOG_FILE"
    }
    ERR_LIST+=("$DOMAIN")
  fi
  log ""
done

log "Summary:"
log "Success: ${#OK_LIST[@]}"; for d in "${OK_LIST[@]}"; do log "  - $d"; done
log ""
log "Failed: ${#ERR_LIST[@]}";  for d in "${ERR_LIST[@]}"; do log "  - $d"; done
log ""
log "Done at $(date)"
log "==========================================="

exit $([ ${#ERR_LIST[@]} -gt 0 ] && echo 1 || echo 0)
