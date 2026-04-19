#!/usr/bin/env bash
# Restore un path depuis le dernier snapshot restic.
# Meme pattern ephemere que backup-run.
#
# Usage: backup-restore <absolute-path>
#   Ex: backup-restore /var/lib/services/ghost
#
# Safety: skip si le path cible existe deja ET contient quelque chose.

set -euo pipefail
set +x

TARGET="${1:-}"
if [[ -z "$TARGET" || "$TARGET" != /* ]]; then
  echo "Usage: $0 <absolute-path>" >&2
  exit 2
fi

# Si le dossier contient deja des donnees, on ne touche pas.
if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  echo "$TARGET non vide, skip restore."
  exit 0
fi

# --- Fetch Infisical creds --------------------------------------------------

CLIENT_ID="$(cat /etc/infisical/client-id)"
CLIENT_SECRET="$(cat /etc/infisical/client-secret)"
PROJECT_ID="$(cat /etc/infisical/project-id)"
ENV_SLUG="$(cat /etc/infisical/environment)"

TOKEN="$(infisical login \
  --method=universal-auth \
  --client-id="$CLIENT_ID" \
  --client-secret="$CLIENT_SECRET" \
  --plain --silent 2>/dev/null)"
if [[ -z "$TOKEN" ]]; then
  echo "Restore: login Infisical echoue, abandon" >&2
  exit 1
fi

fetch() {
  infisical secrets get "$1" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path=/services/backup \
    --token="$TOKEN" --plain 2>/dev/null || true
}

HOME_SSH_PORT="$(fetch HOME_SSH_PORT)"
HOME_SSH_PRIVKEY="$(fetch HOME_SSH_PRIVKEY)"
RESTIC_PASSWORD="$(fetch RESTIC_PASSWORD)"
RESTIC_REPOSITORY="$(fetch RESTIC_REPOSITORY)"

: "${HOME_SSH_PRIVKEY:?HOME_SSH_PRIVKEY manquant}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD manquant}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY manquant}"

HOME_SSH_PORT="${HOME_SSH_PORT:-22}"

# --- ssh-agent ephemere -----------------------------------------------------

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT

printf '%s\n' "$HOME_SSH_PRIVKEY" | ssh-add - 2>/dev/null
HOME_SSH_PRIVKEY=""
unset HOME_SSH_PRIVKEY

# --- Restic restore ---------------------------------------------------------

export RESTIC_PASSWORD RESTIC_REPOSITORY

SFTP_ARGS="-o BatchMode=yes -p ${HOME_SSH_PORT} -o StrictHostKeyChecking=accept-new"

# Si le repo n'existe pas encore, rien a restorer
if ! restic --option sftp.args="$SFTP_ARGS" snapshots >/dev/null 2>&1; then
  echo "Pas de repo restic, rien a restorer."
  exit 0
fi

echo "[$(date -Is)] Restore du dernier snapshot pour $TARGET ..."

# --include <path> = ne restore que ce chemin
# --target / = restore au chemin absolu (meme emplacement qu'a l'origine)
restic --option sftp.args="$SFTP_ARGS" restore latest \
  --include "$TARGET" \
  --target / \
  --verbose=1

echo "[$(date -Is)] Restore done"
