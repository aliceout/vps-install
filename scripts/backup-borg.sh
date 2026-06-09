#!/usr/bin/env bash
# Backup borg multi-folders avec mount-on-demand du disque cible.
#
# Strategie : le disque de backup est UMOUNTED entre les runs -> invisible
# pour le filesystem, ransomware/malware ne peut pas le toucher. Le mount
# n'arrive que pendant les ~10 min du borg create + prune, puis umount.
#
# Lit la config depuis /etc/server-backup/backup-borg.env. Variables :
#   - BORG_REPO              chemin absolu du repo (DOIT etre sous le mount)
#   - BORG_FOLDERS           array "label|source[|exclude]" (existant)
#   - BORG_BIN               (defaut /usr/bin/borg)
#   - BORG_PASSPHRASE        (optionnel : si vide, repo non chiffre)
#   - BORG_KEEP_DAILY        (defaut 7)
#   - BORG_KEEP_WEEKLY       (defaut 4)
#   - BORG_KEEP_MONTHLY      (defaut 12)
#   - BACKUP_DEVICE_UUID     (optionnel : si set, le script mount UUID au
#                             debut et umount a la fin. Si non set, suppose
#                             que BORG_REPO est deja accessible.)
#   - BACKUP_MOUNTPOINT      (requis si BACKUP_DEVICE_UUID set)
#
# Log dans /var/log/server-backup/backup-borg.log (rotate par logrotate).

set -uo pipefail

CONFIG_FILE="/etc/server-backup/backup-borg.env"
LOG_FILE="/var/log/server-backup/backup-borg.log"

if [[ ! -s "$CONFIG_FILE" ]]; then
  echo "ERREUR: config absente: $CONFIG_FILE" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${BORG_REPO:?BORG_REPO non defini dans $CONFIG_FILE}"
: "${BORG_BIN:=/usr/bin/borg}"
BORG_KEEP_DAILY="${BORG_KEEP_DAILY:-7}"
BORG_KEEP_WEEKLY="${BORG_KEEP_WEEKLY:-4}"
BORG_KEEP_MONTHLY="${BORG_KEEP_MONTHLY:-12}"

if [[ -z "${BORG_FOLDERS+x}" ]] || (( ${#BORG_FOLDERS[@]} == 0 )); then
  echo "ERREUR: BORG_FOLDERS vide ou non defini dans $CONFIG_FILE" >&2
  exit 2
fi

install -d -m 755 "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

# --- Mount-on-demand ---------------------------------------------------------
MOUNTED_BY_US=0
if [[ -n "${BACKUP_DEVICE_UUID:-}" ]]; then
  : "${BACKUP_MOUNTPOINT:?BACKUP_MOUNTPOINT requis si BACKUP_DEVICE_UUID set}"
  DEVICE="/dev/disk/by-uuid/$BACKUP_DEVICE_UUID"

  log "=== backup-borg started (mount-on-demand: $DEVICE -> $BACKUP_MOUNTPOINT) ==="

  if ! blkid -s UUID -o value "$DEVICE" >/dev/null 2>&1; then
    log "ERREUR: device $DEVICE introuvable (disque pas branche ?)"
    exit 3
  fi

  # Si pas deja monte, on monte. Si deja monte RO, on remount RW. Si deja RW,
  # on continue mais on UMOUNT a la fin quand meme (cleanup state safe).
  mount_info=$(findmnt -n -o OPTIONS "$BACKUP_MOUNTPOINT" 2>/dev/null || true)
  if [[ -z "$mount_info" ]]; then
    mkdir -p "$BACKUP_MOUNTPOINT"
    if mount -o rw "$DEVICE" "$BACKUP_MOUNTPOINT"; then
      MOUNTED_BY_US=1
      log "Monte RW: $BACKUP_MOUNTPOINT"
    else
      log "ERREUR: mount $DEVICE -> $BACKUP_MOUNTPOINT a echoue"
      exit 3
    fi
  elif echo "$mount_info" | grep -qw ro; then
    if mount -o remount,rw "$BACKUP_MOUNTPOINT"; then
      MOUNTED_BY_US=1
      log "Remonte RW (etait RO): $BACKUP_MOUNTPOINT"
    else
      log "ERREUR: remount RW $BACKUP_MOUNTPOINT a echoue"
      exit 3
    fi
  else
    log "Deja monte RW: $BACKUP_MOUNTPOINT (umount fait quand meme a la fin)"
    MOUNTED_BY_US=1
  fi

  # Trap : si on crash apres le mount, on tente d'umount avant d'exit
  unmount_cleanup() {
    if (( MOUNTED_BY_US == 1 )); then
      log "Cleanup: umount $BACKUP_MOUNTPOINT"
      umount "$BACKUP_MOUNTPOINT" 2>/dev/null || \
        umount -l "$BACKUP_MOUNTPOINT" 2>/dev/null || \
        log "AVERTISSEMENT: umount $BACKUP_MOUNTPOINT a echoue (lazy umount tente)"
    fi
  }
  trap unmount_cleanup EXIT
else
  log "=== backup-borg started (repo=$BORG_REPO, pas de mount on-demand) ==="
fi

# --- Borg config -------------------------------------------------------------
export BORG_REPO
[[ -n "${BORG_PASSPHRASE:-}" ]] && export BORG_PASSPHRASE
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

# Init repo si premiere fois
if [[ ! -d "$BORG_REPO" ]]; then
  log "Init repo borg : $BORG_REPO"
  if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
    "$BORG_BIN" init --encryption=repokey "$BORG_REPO" >>"$LOG_FILE" 2>&1 || {
      log "ERREUR: borg init a echoue"
      exit 3
    }
  else
    "$BORG_BIN" init --encryption=none "$BORG_REPO" >>"$LOG_FILE" 2>&1 || {
      log "ERREUR: borg init a echoue"
      exit 3
    }
  fi
fi

# --- Create archives ---------------------------------------------------------
errors=0

for entry in "${BORG_FOLDERS[@]}"; do
  # Format: "label|source_path[|exclude_path]"
  IFS='|' read -r name src exclude <<< "$entry"
  archive="${name}-$(date +%Y-%m-%d_%H-%M)"
  log "Backup $name -> $archive (src=$src${exclude:+, exclude=$exclude})"

  args=(create --stats --compression auto,zstd)
  [[ -n "$exclude" ]] && args+=(--exclude "$exclude")
  args+=("$BORG_REPO::$archive" "$src")

  if "$BORG_BIN" "${args[@]}" >>"$LOG_FILE" 2>&1; then
    log "OK: $name"
  else
    rc=$?
    log "FAIL: $name (rc=$rc)"
    errors=$((errors + 1))
  fi
done

# --- Prune + compact : auto-cleanup ------------------------------------------
# Une policy par label pour pas qu'un dominant mange tout l'espace.
log "borg prune (keep ${BORG_KEEP_DAILY}d/${BORG_KEEP_WEEKLY}w/${BORG_KEEP_MONTHLY}m, par label)"
for entry in "${BORG_FOLDERS[@]}"; do
  IFS='|' read -r name _ _ <<< "$entry"
  if "$BORG_BIN" prune --stats \
       --keep-daily "$BORG_KEEP_DAILY" \
       --keep-weekly "$BORG_KEEP_WEEKLY" \
       --keep-monthly "$BORG_KEEP_MONTHLY" \
       --glob-archives "${name}-*" \
       "$BORG_REPO" >>"$LOG_FILE" 2>&1; then
    log "prune OK: $name"
  else
    log "prune FAIL: $name (on continue)"
  fi
done

log "borg compact"
if "$BORG_BIN" compact "$BORG_REPO" >>"$LOG_FILE" 2>&1; then
  log "compact OK"
else
  log "compact FAIL (inoffensif)"
fi

# Espace dispo apres
log "Espace dispo sur le repo :"
df -h "$BORG_REPO" 2>>"$LOG_FILE" | tee -a "$LOG_FILE"

log "=== backup-borg ended (errors=$errors) ==="

# Le trap unmount_cleanup est appele en sortie (success ou error) -> SSD invisible
exit $errors
