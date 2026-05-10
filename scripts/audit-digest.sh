#!/usr/bin/env bash
# Digest quotidien des outils d'audit (aide, debsecan, lynis, CrowdSec)
# envoye via Telegram. Ne dit rien si rien d'interessant.

set -euo pipefail

LOG_DIR="/var/log/audit"
HOSTNAME_SHORT="$(hostname -s)"
DATE_HUMAN="$(date +'%Y-%m-%d')"

DIGEST=""

append() {
  DIGEST+="$1"
}

# --- AIDE (file integrity vs baseline) --------------------------------------
if [[ -f "$LOG_DIR/aide.log" ]]; then
  # aide --check ecrit "AIDE found differences..." + un bloc "Summary:" avec
  # les compteurs Added/Removed/Changed. Si tout est clean, message different
  # et on dit rien.
  if grep -q 'found differences' "$LOG_DIR/aide.log" 2>/dev/null; then
    SUMMARY="$(grep -E '^\s*(Added|Removed|Changed) entries' "$LOG_DIR/aide.log" 2>/dev/null | head -3)"
    if [[ -n "$SUMMARY" ]]; then
      append $'\n—— AIDE (changements depuis baseline) ——\n'
      append "$SUMMARY"
      append $'\n'
    fi
  fi
fi

# --- debsecan (CVE avec fix disponible) -------------------------------------
if [[ -f "$LOG_DIR/debsecan.log" ]]; then
  # On prend les 15 premieres lignes du dernier rapport (ignorer blank/header)
  TAIL="$(tac "$LOG_DIR/debsecan.log" 2>/dev/null \
    | awk 'NR<=15 {print}' \
    | tac \
    | grep -vE '^\s*$' || true)"
  if [[ -n "$TAIL" ]]; then
    append $'\n—— debsecan (CVE patchables) ——\n'
    append "$TAIL"
    append $'\n'
  fi
fi

# --- lynis (count warnings + suggestions) -----------------------------------
if [[ -f "$LOG_DIR/lynis.log" ]]; then
  WARN_CNT="$(grep -cE 'Warning:|\[WARNING\]' "$LOG_DIR/lynis.log" 2>/dev/null || echo 0)"
  SUG_CNT="$(grep -cE 'Suggestion:|\[SUGGESTION\]' "$LOG_DIR/lynis.log" 2>/dev/null || echo 0)"
  if [[ "$WARN_CNT" -gt 0 || "$SUG_CNT" -gt 0 ]]; then
    append $'\n—— lynis ——\n'
    append "Warnings: $WARN_CNT, Suggestions: $SUG_CNT"
    append $'\n'
  fi
fi

# --- CrowdSec (decisions actives) -------------------------------------------
if command -v cscli >/dev/null 2>&1; then
  N_DEC="$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l || echo 0)"
  if [[ "$N_DEC" -gt 0 ]]; then
    append $'\n—— CrowdSec ——\n'
    append "Bans actifs : $N_DEC"
    append $'\n'
  fi
fi

# --- Envoi ------------------------------------------------------------------
if [[ -n "$DIGEST" ]]; then
  {
    echo "🛡️ Audit VPS ${HOSTNAME_SHORT} (${DATE_HUMAN})"
    echo "$DIGEST"
  } | /usr/local/sbin/notify-telegram --target audit
fi
