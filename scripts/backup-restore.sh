#!/usr/bin/env bash
# Restore depuis le miroir rsync cote home server.
# Reverse rsync (home -> VPS) sur le path demande.
#
# Usage: backup-restore <absolute-path>
#   Ex: backup-restore /home/choupi/data/ghost
#
# Safety: skip si le path cible existe deja ET contient quelque chose.
#
# Note: ne restore que l'etat COURANT du miroir cote home. Pour un retour
# arriere a un point dans le passe, parcourir les snapshots Borg cote home
# (les data du VPS sont versionnees la-bas).

set -euo pipefail
set +x

TARGET="${1:-}"
if [[ -z "$TARGET" || "$TARGET" != /* ]]; then
  echo "Usage: $0 <absolute-path>" >&2
  exit 2
fi

if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
  echo "$TARGET non vide, skip restore."
  exit 0
fi

# --- Fetch Infisical creds --------------------------------------------------

PROJECT_ID="$(cat /etc/infisical/project-id)"
ENV_SLUG="$(cat /etc/infisical/environment)"

TOKEN="$(infi-token --silent 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "Restore: login Infisical echoue, abandon" >&2
  exit 1
fi
DOMAIN="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"

BACKUP_PATH="/infra/vps/backup"
SERVER_PATH="/infra/server"

# fetch <key> [path]  (path defaut = /infra/vps/backup)
fetch() {
  local key="$1" path="${2:-$BACKUP_PATH}"
  infisical secrets get "$key" \
    --domain="$DOMAIN" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path="$path" \
    --token="$TOKEN" --plain 2>/dev/null || true
}

HOME_SSH_HOST="$(fetch HOME_SSH_HOST)"
HOME_SSH_USER="$(fetch HOME_SSH_USER)"
HOME_SSH_PRIVKEY="$(fetch HOME_SSH_PRIVKEY)"
REMOTE_PATH="$(fetch REMOTE_PATH)"
SOURCE_PATH="$(fetch SOURCE_PATH)"

# Port : HOME_SSH_PORT sous /infra/vps/backup si present, sinon SSH_PORT
# sous /infra/server, sinon 22.
HOME_SSH_PORT="$(fetch HOME_SSH_PORT)"
[[ -z "$HOME_SSH_PORT" ]] && HOME_SSH_PORT="$(fetch SSH_PORT "$SERVER_PATH")"

: "${HOME_SSH_HOST:?HOME_SSH_HOST manquant dans /infra/vps/backup/}"
: "${HOME_SSH_USER:?HOME_SSH_USER manquant}"
: "${HOME_SSH_PRIVKEY:?HOME_SSH_PRIVKEY manquant}"
: "${REMOTE_PATH:?REMOTE_PATH manquant}"

HOME_SSH_PORT="${HOME_SSH_PORT:-22}"

if [[ -z "${SOURCE_PATH:-}" ]]; then
  VPS_USER_NAME="$(cat /etc/infisical/vps-user 2>/dev/null || echo '')"
  SOURCE_PATH="/home/${VPS_USER_NAME}/data"
fi
SOURCE_PATH="${SOURCE_PATH%/}"
REMOTE_PATH="${REMOTE_PATH%/}"

# TARGET doit etre sous SOURCE_PATH pour qu'on sache ou il vit cote home.
# Ex: SOURCE_PATH=/home/choupi/data, TARGET=/home/choupi/data/ghost
#     -> sub_path=ghost -> remote: REMOTE_PATH/ghost/
case "$TARGET" in
  "$SOURCE_PATH"|"$SOURCE_PATH"/*) ;;
  *)
    echo "Restore: TARGET ($TARGET) hors de SOURCE_PATH ($SOURCE_PATH), pas dans le scope du miroir." >&2
    exit 2
    ;;
esac
sub_path="${TARGET#$SOURCE_PATH}"
sub_path="${sub_path#/}"

# --- ssh-agent ephemere -----------------------------------------------------

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT

ssh_add_rc=0
ssh_add_out="$(printf '%s\n' "$HOME_SSH_PRIVKEY" | ssh-add - 2>&1)" || ssh_add_rc=$?
if [[ $ssh_add_rc -ne 0 ]]; then
  echo "Restore: ssh-add KO (rc=$ssh_add_rc): $ssh_add_out" >&2
  exit 1
fi
HOME_SSH_PRIVKEY=""
unset HOME_SSH_PRIVKEY ssh_add_out ssh_add_rc

# --- Reverse rsync ----------------------------------------------------------

mkdir -p "$TARGET"

remote_src="${REMOTE_PATH}/${sub_path}"
[[ -n "$sub_path" ]] && remote_src="${remote_src%/}/"

echo "[$(date -Is)] backup-restore: ${HOME_SSH_USER}@${HOME_SSH_HOST}:${remote_src} -> $TARGET/"

rsync -av \
  -e "ssh -p ${HOME_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
  "${HOME_SSH_USER}@${HOME_SSH_HOST}:${remote_src}" \
  "${TARGET%/}/"

echo "[$(date -Is)] backup-restore OK"
