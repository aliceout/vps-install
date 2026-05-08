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
#
# Notif Telegram sur echec : pipe la queue de la sortie dans
# `notify-telegram --target certbot` pour que tu sois prevenu si un renew
# casse (sinon les certs expirent en silence et tout va en 502).

set -euo pipefail

CERTBOT_BIN="/usr/local/bin/certbot"
[[ -x "$CERTBOT_BIN" ]] || CERTBOT_BIN="$(command -v certbot || true)"
[[ -n "$CERTBOT_BIN" ]] || { echo "certbot introuvable" >&2; exit 1; }

LOG_DIR="/var/log/cron"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/certbot-dns-$(date +%F).log"
TMP_LOG="$(mktemp)"
trap 'rm -f "$TMP_LOG"' EXIT

{
  echo ""
  echo "=========================================="
  echo "certbot renew: $(date)"
  echo "=========================================="
} | tee -a "$LOG_FILE" "$TMP_LOG"

"$CERTBOT_BIN" renew --non-interactive 2>&1 | tee -a "$LOG_FILE" "$TMP_LOG" || true
rc="${PIPESTATUS[0]}"

{
  echo ""
  echo "certbot renew exit $rc ($(date))"
  echo "=========================================="
} | tee -a "$LOG_FILE" "$TMP_LOG"

if [[ "$rc" -ne 0 ]] && command -v notify-telegram >/dev/null 2>&1; then
  {
    echo "❌ Certbot renew echoue sur $(hostname)"
    echo ""
    echo "Exit code: $rc"
    echo ""
    echo "Sortie (queue) :"
    tail -30 "$TMP_LOG"
  } | notify-telegram --target certbot || true
fi

exit "$rc"
