#!/usr/bin/env bash
set -euo pipefail

LOG_DIR="/var/log/cron"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/fail2ban-list-$(date +%F).log"

SOURCES=(
  "https://iplists.firehol.org/files/firehol_level1.netset"
  "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt"
  "https://www.binarydefense.com/banlist.txt"
)

TMP_FILE="$(mktemp)"
TMP_UNIQ="${TMP_FILE}.uniq"

cleanup() {
  rm -f "$TMP_FILE" "$TMP_UNIQ"
}
trap cleanup EXIT

log() { echo "$1" | tee -a "$LOG_FILE"; }

log ""
log "Start $(date)"

for url in "${SOURCES[@]}"; do
  log "Fetch: $url"
  curl -fsSL "$url" \
    | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[1-2][0-9]|3[0-2]))?' \
    >> "$TMP_FILE" || true
done

sort -u "$TMP_FILE" > "$TMP_UNIQ"
COUNT="$(wc -l < "$TMP_UNIQ" | tr -d ' ')"

if [[ "${COUNT}" -eq 0 ]]; then
  log "No IPs found, abort."
  exit 1
fi

systemctl is-active --quiet fail2ban || systemctl start fail2ban
fail2ban-client reload || true

log "Ban ${COUNT} IPs/CIDR via fail2ban badips"
xargs -a "$TMP_UNIQ" -n 200 fail2ban-client set badips banip

log "Done $(date)"
