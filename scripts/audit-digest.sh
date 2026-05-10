#!/usr/bin/env bash
# Digest quotidien des outils d'audit (aide, lynis, CrowdSec) envoye via
# Telegram. Ne dit rien si rien d'interessant, sauf le heartbeat CrowdSec
# du dimanche qui confirme que le bouncer est vivant.

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

# --- lynis (count warnings + suggestions) -----------------------------------
# grep -c sort toujours un nombre, pas besoin de "|| echo 0" qui produit "0\n0"
# et casse l'eval numerique de [[ -gt ]] (silently skip de la section).
if [[ -f "$LOG_DIR/lynis.log" ]]; then
  WARN_CNT="$(grep -cE 'Warning:|\[WARNING\]' "$LOG_DIR/lynis.log" 2>/dev/null)"
  SUG_CNT="$(grep -cE 'Suggestion:|\[SUGGESTION\]' "$LOG_DIR/lynis.log" 2>/dev/null)"
  if [[ "${WARN_CNT:-0}" -gt 0 || "${SUG_CNT:-0}" -gt 0 ]]; then
    append $'\n—— lynis ——\n'
    append "Warnings: ${WARN_CNT:-0}, Suggestions: ${SUG_CNT:-0}"
    append $'\n'
  fi
fi

# --- CrowdSec (decisions actives + heartbeat hebdo) --------------------------
# Heartbeat dimanche : on push systematiquement le compteur, meme s'il est a 0,
# pour confirmer que le bouncer est vivant. Les autres jours, on ne dit rien
# si pas de bans actifs.
if command -v cscli >/dev/null 2>&1; then
  N_DEC="$(cscli decisions list -o raw 2>/dev/null | tail -n +2 | wc -l)"
  N_DEC="${N_DEC:-0}"
  IS_SUNDAY=0
  [[ "$(date +%u)" == "7" ]] && IS_SUNDAY=1
  if [[ "$N_DEC" -gt 0 || "$IS_SUNDAY" == 1 ]]; then
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
