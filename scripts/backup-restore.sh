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

PROJECT_ID="$(cat /etc/infisical/project-id)"
ENV_SLUG="$(cat /etc/infisical/environment)"

# infi-token gere creds, domain self-hosted et cache 10min.
TOKEN="$(infi-token --silent 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
  echo "Restore: login Infisical echoue, abandon" >&2
  exit 1
fi
DOMAIN="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"

fetch() {
  infisical secrets get "$1" \
    --domain="$DOMAIN" \
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

# Check explicitement le rc : si ssh-add echoue (cle malformee, agent KO),
# restic tomberait sur un prompt password silencieux et hang.
ssh_add_rc=0
ssh_add_out="$(printf '%s\n' "$HOME_SSH_PRIVKEY" | ssh-add - 2>&1)" || ssh_add_rc=$?
if [[ $ssh_add_rc -ne 0 ]]; then
  echo "Restore: ssh-add KO (rc=$ssh_add_rc): $ssh_add_out" >&2
  exit 1
fi
HOME_SSH_PRIVKEY=""
unset HOME_SSH_PRIVKEY ssh_add_out ssh_add_rc

# --- Restic restore ---------------------------------------------------------

export RESTIC_PASSWORD RESTIC_REPOSITORY

SFTP_ARGS="-o BatchMode=yes -p ${HOME_SSH_PORT} -o StrictHostKeyChecking=accept-new"

# Si le repo n'existe pas encore, rien a restorer
if ! restic --option sftp.args="$SFTP_ARGS" snapshots >/dev/null 2>&1; then
  echo "Pas de repo restic, rien a restorer."
  exit 0
fi

echo "[$(date -Is)] Restore du dernier snapshot pour $TARGET ..."

# --path <abs-path>  = filtre 'latest' aux snapshots qui ont effectivement
#                      backup $TARGET (sinon on pourrait piocher un snapshot
#                      sans cette donnee)
# --include <path>   = filtre les chemins a restorer (literal-segment match,
#                      donc 'foo' ne capture pas 'foo-old')
# --target /         = restore aux chemins absolus d'origine
restic --option sftp.args="$SFTP_ARGS" restore latest \
  --path "$TARGET" \
  --include "$TARGET" \
  --target / \
  --verbose=1

echo "[$(date -Is)] Restore done"
