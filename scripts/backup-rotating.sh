#!/usr/bin/env bash
# Rotating tar+xz backups : daily/weekly/monthly avec rotation auto.
# Source config /etc/server-backup/backup-rotating.env qui declare :
#   - BACKUP_DEST              dossier de destination
#   - FOLDERS                  associative array name -> path source
#   - EXCLUDES                 associative array name -> path a exclure
#   - ROTATION_DAILY_DAYS      (defaut 14)
#   - ROTATION_WEEKLY_DAYS     (defaut 90)
#   - ROTATION_MONTHLY_DAYS    (defaut 300)
#
# Strategie : 1er du mois -> monthly, samedi -> weekly, autres -> daily.
# Logique de prefix preservee depuis l'original zsh, juste portee en bash.

set -Eeuo pipefail

CONFIG="/etc/server-backup/backup-rotating.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "[backup-rotating] ERREUR: $CONFIG absent" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${BACKUP_DEST:?BACKUP_DEST manquant dans $CONFIG}"
ROTATION_DAILY_DAYS="${ROTATION_DAILY_DAYS:-14}"
ROTATION_WEEKLY_DAYS="${ROTATION_WEEKLY_DAYS:-90}"
ROTATION_MONTHLY_DAYS="${ROTATION_MONTHLY_DAYS:-300}"

if ! declare -p FOLDERS &>/dev/null; then
  echo "[backup-rotating] ERREUR: FOLDERS (associative array) non defini dans $CONFIG" >&2
  exit 1
fi

LOG_DIR="/var/log/server-backup"
mkdir -p "$LOG_DIR" "$BACKUP_DEST"
LOG="$LOG_DIR/backup-rotating-$(date +%F).log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

today=$(date +%d-%m-%Y)
week=$(date +"%V-wk-%m-%Y")
month=$(date +%m-%Y)
day_num=$(date +%d)
week_day=$(date +%u)

if [[ "$day_num" == "01" ]]; then
  prefix="monthly-$month"
elif [[ "$week_day" == "6" ]]; then
  prefix="weekly-$week"
else
  prefix="daily-$today"
fi

log "=== backup-rotating started ($prefix) ==="
exit_code=0
for name in "${!FOLDERS[@]}"; do
  src="${FOLDERS[$name]}"
  dest="$BACKUP_DEST/$name"
  mkdir -p "$dest"
  archive="$dest/$prefix.tar.xz"

  # Excludes optionnels (peuvent etre plusieurs paths separes par espaces)
  exclude_args=()
  if [[ -n "${EXCLUDES[$name]:-}" ]]; then
    for ex in ${EXCLUDES[$name]}; do
      exclude_args+=("--exclude=$ex")
    done
  fi

  log "Backing up $name -> $archive"
  if tar -cJf "$archive" "${exclude_args[@]}" $src 2>>"$LOG"; then
    log "OK $name"
  else
    log "FAIL $name"
    exit_code=1
    continue
  fi

  # Rotation par age (find -mtime)
  find "$dest" -type f -name 'daily-*.tar.xz'   -mtime "+$ROTATION_DAILY_DAYS"   -delete 2>/dev/null || true
  find "$dest" -type f -name 'weekly-*.tar.xz'  -mtime "+$ROTATION_WEEKLY_DAYS"  -delete 2>/dev/null || true
  find "$dest" -type f -name 'monthly-*.tar.xz' -mtime "+$ROTATION_MONTHLY_DAYS" -delete 2>/dev/null || true
done

log "=== backup-rotating done (exit=$exit_code) ==="
exit $exit_code
