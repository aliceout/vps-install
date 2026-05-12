#!/usr/bin/env bash
# Backup runner : fetch creds from Infisical (RAM only), ssh-agent ephemere,
# restic backup + forget. La cle privee SSH n'est JAMAIS ecrite sur disque.
#
# Usage: backup-run
# Declenche par cron (/etc/cron.d/vps-backup).

set -euo pipefail
# Disable tracing explicitement au cas ou appele avec bash -x (eviterait
# que la cle apparaisse dans les logs).
set +x

# --- Fetch Infisical creds (/services/backup/) ------------------------------

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
  echo "Backup: login Infisical echoue, abandon" >&2
  exit 1
fi

fetch() {
  infisical secrets get "$1" \
    --projectId="$PROJECT_ID" --env="$ENV_SLUG" --path=/services/backup \
    --token="$TOKEN" --plain 2>/dev/null || true
}

HOME_SSH_HOST="$(fetch HOME_SSH_HOST)"
HOME_SSH_PORT="$(fetch HOME_SSH_PORT)"
HOME_SSH_PRIVKEY="$(fetch HOME_SSH_PRIVKEY)"
RESTIC_PASSWORD="$(fetch RESTIC_PASSWORD)"
RESTIC_REPOSITORY="$(fetch RESTIC_REPOSITORY)"
BACKUP_PATHS="$(fetch BACKUP_PATHS)"

: "${HOME_SSH_HOST:?HOME_SSH_HOST manquant dans /services/backup/}"
: "${HOME_SSH_PRIVKEY:?HOME_SSH_PRIVKEY manquant}"
: "${RESTIC_PASSWORD:?RESTIC_PASSWORD manquant}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY manquant}"

HOME_SSH_PORT="${HOME_SSH_PORT:-22}"

# Default: /home/<VPS_USER>/data/ est LA racine de toutes les donnees
# persistantes des services. Chaque service met ses volumes dans
# /home/<VPS_USER>/data/<service-name>/.
if [[ -z "${BACKUP_PATHS:-}" ]]; then
  VPS_USER_NAME="$(cat /etc/infisical/vps-user 2>/dev/null || echo '')"
  if [[ -n "$VPS_USER_NAME" ]]; then
    BACKUP_PATHS="/home/${VPS_USER_NAME}/data"
  else
    BACKUP_PATHS="/var/lib/services"
  fi
fi

# --- ssh-agent ephemere -----------------------------------------------------

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT

# Pipe la cle dans l'agent via stdin. Pas d'ecriture disque.
# Check explicitement le rc : si ssh-add echoue (cle malformee, agent KO),
# restic tomberait sur un prompt password en cron silencieux et hang.
ssh_add_rc=0
ssh_add_out="$(printf '%s\n' "$HOME_SSH_PRIVKEY" | ssh-add - 2>&1)" || ssh_add_rc=$?
if [[ $ssh_add_rc -ne 0 ]]; then
  echo "Backup: ssh-add KO (rc=$ssh_add_rc): $ssh_add_out" >&2
  exit 1
fi
# On peut clear la var maintenant que la cle est dans l'agent
HOME_SSH_PRIVKEY=""
unset HOME_SSH_PRIVKEY ssh_add_out ssh_add_rc

# --- Restic -----------------------------------------------------------------

export RESTIC_PASSWORD RESTIC_REPOSITORY

# Options SSH passees par restic a ssh (qui utilisera SSH_AUTH_SOCK de l'agent)
SFTP_ARGS="-o BatchMode=yes -p ${HOME_SSH_PORT} -o StrictHostKeyChecking=accept-new"

echo "[$(date -Is)] Restic backup: $BACKUP_PATHS -> $RESTIC_REPOSITORY"

# Init repo a la volee s'il est vide
if ! restic --option sftp.args="$SFTP_ARGS" snapshots >/dev/null 2>&1; then
  echo "Repo absent, init..."
  restic --option sftp.args="$SFTP_ARGS" init
fi

# shellcheck disable=SC2086
restic --option sftp.args="$SFTP_ARGS" backup $BACKUP_PATHS \
  --host "$(hostname -s)" \
  --tag vps-auto \
  --exclude-caches \
  --verbose=1

# Retention : 7 jours. Le home server gere les retentions longues
# via ses propres snapshots / RAID / disque externe.
restic --option sftp.args="$SFTP_ARGS" forget --keep-daily 7 --prune

echo "[$(date -Is)] Backup done"
