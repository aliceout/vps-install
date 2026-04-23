#!/usr/bin/env bash
# Renouvellement en masse des certs Let's Encrypt.
#
# On delegue a `certbot renew` : chaque cert emis precedemment a enregistre
# son plugin + son credentials path dans /etc/letsencrypt/renewal/<name>.conf,
# donc renew sait deja quel provider DNS utiliser par cert. Le pre-hook
# /etc/letsencrypt/renewal-hooks/pre/refresh-creds regenere les ini files
# depuis Infisical avant chaque tentative (rotation de token transparente).
#
# Lance manuellement ou via le cron de 70_cron_updates.sh (en plus de
# certbot.timer).

set -euo pipefail

CERTBOT_BIN="/usr/local/bin/certbot"
[[ -x "$CERTBOT_BIN" ]] || CERTBOT_BIN="$(command -v certbot || true)"
[[ -n "$CERTBOT_BIN" ]] || { echo "certbot introuvable" >&2; exit 1; }

LOG_DIR="/var/log/cron"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/certbot-dns-$(date +%F).log"

{
  echo ""
  echo "=========================================="
  echo "certbot renew: $(date)"
  echo "=========================================="

  "$CERTBOT_BIN" renew --non-interactive 2>&1
  rc=$?

  echo ""
  echo "certbot renew exit $rc ($(date))"
  echo "=========================================="
} | tee -a "$LOG_FILE"

exit "${PIPESTATUS[0]}"
