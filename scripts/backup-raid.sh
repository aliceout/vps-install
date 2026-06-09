#!/usr/bin/env bash
# Backup-raid : borg vers SSD externe (UUID-based mount). Remplace l'ancien
# rsync --delete qui foirait si SSD < source.
#
# Avantages vs rsync :
# - Compression + dedup -> typiquement -50 a -80% de taille
# - Snapshots point-in-time avec retention auto (daily/weekly/monthly)
# - Borg prune + compact = auto-cleanup quand vieux snapshots virent
# - Si SSD se remplit, on a un message clair "Out of space" pas un mirroir
#   tronque silencieusement
#
# Le SSD est remonte en read-only apres backup pour limiter les degats en
# cas de ransomware actif sur le host.
#
# Source config /etc/server-backup/backup-raid.env :
#   - BACKUP_RAID_DEVICE_UUID    UUID du device (cf blkid)
#   - BACKUP_RAID_MOUNTPOINT     dossier de mount (cree si absent)
#   - BACKUP_RAID_SOURCE         dossier source a backuper
#   - BORG_REPO_RELATIVE         sous-dossier sur le SSD pour le repo borg
#                                (defaut "borg-repo")
#   - BORG_KEEP_DAILY            defaut 7
#   - BORG_KEEP_WEEKLY           defaut 4
#   - BORG_KEEP_MONTHLY          defaut 12
#   - BORG_PASSPHRASE            si vide, repo non chiffre (acceptable pour
#                                SSD physique sous controle)
#   - BORG_EXCLUDE               liste de paths a exclure, separes par espaces

set -Eeuo pipefail

CONFIG="/etc/server-backup/backup-raid.env"
if [[ ! -f "$CONFIG" ]]; then
  echo "[backup-raid] ERREUR: $CONFIG absent" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG"

: "${BACKUP_RAID_DEVICE_UUID:?BACKUP_RAID_DEVICE_UUID manquant dans $CONFIG}"
: "${BACKUP_RAID_MOUNTPOINT:?BACKUP_RAID_MOUNTPOINT manquant dans $CONFIG}"
: "${BACKUP_RAID_SOURCE:?BACKUP_RAID_SOURCE manquant dans $CONFIG}"

BORG_REPO_RELATIVE="${BORG_REPO_RELATIVE:-borg-repo}"
BORG_KEEP_DAILY="${BORG_KEEP_DAILY:-7}"
BORG_KEEP_WEEKLY="${BORG_KEEP_WEEKLY:-4}"
BORG_KEEP_MONTHLY="${BORG_KEEP_MONTHLY:-12}"

DEVICE="/dev/disk/by-uuid/$BACKUP_RAID_DEVICE_UUID"
REPO="$BACKUP_RAID_MOUNTPOINT/$BORG_REPO_RELATIVE"
HOSTNAME_SHORT="$(hostname -s)"
ARCHIVE_NAME="${HOSTNAME_SHORT}-$(date +%Y-%m-%d_%H-%M)"

LOG_DIR="/var/log/server-backup"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/backup-raid.log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

cleanup() {
  # Best-effort umount en cas de fail.
  if findmnt -n "$BACKUP_RAID_MOUNTPOINT" >/dev/null 2>&1; then
    umount "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true
  fi
}
trap cleanup ERR

# Export pour borg
export BORG_REPO="$REPO"
[[ -n "${BORG_PASSPHRASE:-}" ]] && export BORG_PASSPHRASE
export BORG_RELOCATED_REPO_ACCESS_IS_OK=yes
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=yes

log "=== backup-raid started ==="

# 1. Verifier que le device existe
if ! blkid -s UUID -o value "$DEVICE" >/dev/null 2>&1; then
  log "ERREUR: device $DEVICE introuvable (disque pas branche ?)"
  exit 1
fi
log "UUID $BACKUP_RAID_DEVICE_UUID present : OK"

# 2. Mount ou remount RW
mount_info=$(findmnt -n -o SOURCE,TARGET,OPTIONS "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true)
if [[ -z "$mount_info" ]]; then
  log "Montage RW de $DEVICE sur $BACKUP_RAID_MOUNTPOINT"
  mkdir -p "$BACKUP_RAID_MOUNTPOINT"
  mount -o rw "$DEVICE" "$BACKUP_RAID_MOUNTPOINT"
elif echo "$mount_info" | grep -qw ro; then
  log "Remontage RW (etait RO)"
  mount -o remount,rw "$BACKUP_RAID_MOUNTPOINT"
else
  log "Deja monte RW"
fi

# 3. Initialiser le repo borg si premiere fois
if [[ ! -d "$REPO" ]]; then
  log "Init repo borg : $REPO"
  if [[ -n "${BORG_PASSPHRASE:-}" ]]; then
    borg init --encryption=repokey "$REPO"
  else
    borg init --encryption=none "$REPO"
  fi
fi

# 4. Espace dispo avant
log "Espace dispo avant :"
df -h "$BACKUP_RAID_MOUNTPOINT" | tee -a "$LOG"

# 5. Create archive
EXCLUDE_ARGS=()
if [[ -n "${BORG_EXCLUDE:-}" ]]; then
  for path in $BORG_EXCLUDE; do
    EXCLUDE_ARGS+=("--exclude" "$path")
  done
fi

log "borg create $ARCHIVE_NAME (source=$BACKUP_RAID_SOURCE)"
if borg create --stats --compression auto,zstd \
   "${EXCLUDE_ARGS[@]}" \
   "$REPO::$ARCHIVE_NAME" \
   "$BACKUP_RAID_SOURCE" >>"$LOG" 2>&1; then
  log "borg create OK"
else
  rc=$?
  log "borg create FAIL (rc=$rc)"
  umount "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true
  exit $rc
fi

# 6. Prune : retention policy auto
log "borg prune (keep ${BORG_KEEP_DAILY}d/${BORG_KEEP_WEEKLY}w/${BORG_KEEP_MONTHLY}m)"
if borg prune --stats \
   --keep-daily "$BORG_KEEP_DAILY" \
   --keep-weekly "$BORG_KEEP_WEEKLY" \
   --keep-monthly "$BORG_KEEP_MONTHLY" \
   --glob-archives "${HOSTNAME_SHORT}-*" \
   "$REPO" >>"$LOG" 2>&1; then
  log "borg prune OK"
else
  log "borg prune FAIL (rc=$?) -- on continue quand meme"
fi

# 7. Compact : reclaim de l'espace libere par le prune
log "borg compact"
if borg compact "$REPO" >>"$LOG" 2>&1; then
  log "borg compact OK"
else
  log "borg compact FAIL (rc=$?) -- inoffensif, juste pas reclaim immediat"
fi

# 8. Espace dispo apres
log "Espace dispo apres :"
df -h "$BACKUP_RAID_MOUNTPOINT" | tee -a "$LOG"

# 9. Liste des archives presentes
log "Archives presentes :"
borg list "$REPO" 2>>"$LOG" | tee -a "$LOG"

# 10. Remount RO (safety contre ransomware host)
log "Remontage RO"
if mount -o remount,ro "$BACKUP_RAID_MOUNTPOINT"; then
  log "Remontage RO OK"
else
  log "Remontage RO impossible, umount force"
  umount "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true
  exit 1
fi

trap - ERR
log "=== backup-raid done ==="
