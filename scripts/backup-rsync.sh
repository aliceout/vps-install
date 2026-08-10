#!/usr/bin/env bash
# Backup runner : rsync miroir des data VPS vers le home server via SSH.
#
# Pas d'encryption, pas de dedup, pas de snapshots cote VPS. Juste un miroir.
# L'historique vit cote home : Borg snapshote le dossier de destination, donc
# les versions anterieures sont accessibles depuis ses snapshots.
#
# La cle privee SSH ne touche JAMAIS le disque : on la pipe dans un ssh-agent
# ephemere qui meurt en fin de run.
#
# Declenche par cron (/etc/cron.d/vps-backup).
#
# Secrets Infisical sous /infra/vps/backup/ (convention infra du repo) :
#   - HOME_SSH_HOST     (required) domaine/IP du home. Idealement un domaine
#                       deja suivi par le dns-sync du home -> DDNS gratuit,
#                       pas d'IP a maintenir a la main.
#   - HOME_SSH_USER     (required) user SSH dedie cote home (ex backup-vps)
#   - HOME_SSH_PRIVKEY  (required) cle privee ed25519 multiligne
#   - REMOTE_PATH       (required) dossier de destination cote home
#   - SOURCE_PATH       (optionnel, defaut /home/$VPS_USER/data)
#   - HOME_SSH_PORT     (optionnel) port SSH du home. A defaut on lit
#                       SSH_PORT sous /infra/server, sinon 22.

set -euo pipefail
# Disable tracing pour eviter une fuite de la cle dans les logs
set +x

# --- Fetch Infisical creds --------------------------------------------------

PROJECT_ID="$(cat /etc/infisical/project-id)"
ENV_SLUG="$(cat /etc/infisical/environment)"

TOKEN="$(infi-token --silent 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "Backup: login Infisical echoue, abandon" >&2
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

# Port : HOME_SSH_PORT sous /infra/vps/backup si present, sinon on reutilise
# SSH_PORT sous /infra/server (le port SSH du home), sinon 22.
HOME_SSH_PORT="$(fetch HOME_SSH_PORT)"
[[ -z "$HOME_SSH_PORT" ]] && HOME_SSH_PORT="$(fetch SSH_PORT "$SERVER_PATH")"

: "${HOME_SSH_HOST:?HOME_SSH_HOST manquant dans /infra/vps/backup/}"
: "${HOME_SSH_USER:?HOME_SSH_USER manquant}"
: "${HOME_SSH_PRIVKEY:?HOME_SSH_PRIVKEY manquant}"
: "${REMOTE_PATH:?REMOTE_PATH manquant}"

HOME_SSH_PORT="${HOME_SSH_PORT:-22}"

if [[ -z "${SOURCE_PATH:-}" ]]; then
  VPS_USER_NAME="$(cat /etc/infisical/vps-user 2>/dev/null || echo '')"
  if [[ -n "$VPS_USER_NAME" ]]; then
    SOURCE_PATH="/home/${VPS_USER_NAME}/data"
  else
    echo "Backup: SOURCE_PATH non defini et /etc/infisical/vps-user manquant" >&2
    exit 1
  fi
fi

# rsync attend un trailing slash sur la source pour copier *le contenu*
# de la source, pas le dossier lui-meme
SOURCE_PATH="${SOURCE_PATH%/}/"
REMOTE_PATH="${REMOTE_PATH%/}"

# --- ssh-agent ephemere -----------------------------------------------------

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT

ssh_add_rc=0
ssh_add_out="$(printf '%s\n' "$HOME_SSH_PRIVKEY" | ssh-add - 2>&1)" || ssh_add_rc=$?
if [[ $ssh_add_rc -ne 0 ]]; then
  echo "Backup: ssh-add KO (rc=$ssh_add_rc): $ssh_add_out" >&2
  exit 1
fi
HOME_SSH_PRIVKEY=""
unset HOME_SSH_PRIVKEY ssh_add_out ssh_add_rc

# --- Rsync ------------------------------------------------------------------

echo "[$(date -Is)] backup-rsync start : $SOURCE_PATH -> ${HOME_SSH_USER}@${HOME_SSH_HOST}:${REMOTE_PATH}/"

# -a : archive (recursif, perms, ownership, timestamps, symlinks)
# -v : verbose (file list pour le log)
# --delete : supprime cote dest ce qui n'existe plus cote source
#            (l'historique est preserve par Borg cote home)
# accept-new : ajoute le host key au known_hosts si inconnu (1er run)
rsync -av --delete \
  -e "ssh -p ${HOME_SSH_PORT} -o BatchMode=yes -o StrictHostKeyChecking=accept-new" \
  "$SOURCE_PATH" \
  "${HOME_SSH_USER}@${HOME_SSH_HOST}:${REMOTE_PATH}/"

echo "[$(date -Is)] backup-rsync OK"
