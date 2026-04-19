#!/usr/bin/env bash
# Send a message to a Telegram bot, optionally routed to a specific channel.
#
# Usage:
#   notify-telegram "Message text"
#   notify-telegram --target audit "Message text"
#   echo "Message" | notify-telegram --target backup
#
# Secrets lus a chaque run depuis Infisical (/vps/_infra/) :
#   - TELEGRAM_BOT_TOKEN            (le bot, partage)
#   - TELEGRAM_CHAT_ID              (fallback)
#   - TELEGRAM_CHAT_ID_<TARGET>     (si --target <name> est passe)
#
# Si le token ou l'id du target manque, skip silencieux (exit 0) pour ne
# pas casser les chaines de cron.

set -euo pipefail
set +x

TARGET=""
if [[ "${1:-}" == "--target" ]]; then
  TARGET="$(echo "${2:-}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  shift 2
fi

MSG="${1:-}"
if [[ -z "$MSG" && ! -t 0 ]]; then
  MSG="$(cat)"
fi
[[ -z "$MSG" ]] && exit 0

# --- Fetch Infisical ---------------------------------------------------------

CLIENT_ID="$(cat /etc/infisical/client-id 2>/dev/null || true)"
CLIENT_SECRET="$(cat /etc/infisical/client-secret 2>/dev/null || true)"
PROJECT_ID="$(cat /etc/infisical/project-id 2>/dev/null || true)"
ENV_SLUG="$(cat /etc/infisical/environment 2>/dev/null || true)"
if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "Infisical creds absents, skip Telegram" >&2
  exit 0
fi

TOKEN="$(infisical login \
  --method=universal-auth \
  --client-id="$CLIENT_ID" --client-secret="$CLIENT_SECRET" \
  --plain --silent 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "Login Infisical echoue, skip Telegram" >&2
  exit 0
fi

fetch() {
  infisical secrets get "$1" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path=/vps/_infra \
    --token="$TOKEN" --plain 2>/dev/null || true
}

BOT_TOKEN="$(fetch TELEGRAM_BOT_TOKEN)"
CHAT_ID=""

# Si un target est demande, on cherche d'abord TELEGRAM_CHAT_ID_<TARGET>,
# puis fallback sur TELEGRAM_CHAT_ID si pas trouve.
if [[ -n "$TARGET" ]]; then
  CHAT_ID="$(fetch "TELEGRAM_CHAT_ID_${TARGET}")"
fi
if [[ -z "$CHAT_ID" ]]; then
  CHAT_ID="$(fetch TELEGRAM_CHAT_ID)"
fi

if [[ -z "$BOT_TOKEN" || -z "$CHAT_ID" ]]; then
  echo "TELEGRAM_BOT_TOKEN ou TELEGRAM_CHAT_ID${TARGET:+_$TARGET} manquant, skip" >&2
  exit 0
fi

# Telegram limit = 4096 chars, marge a 3900
MSG="$(printf '%s' "$MSG" | head -c 3900)"

curl --max-time 10 -sS -X POST \
  "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MSG}" \
  > /dev/null || {
  echo "Telegram API KO" >&2
  exit 1
}
