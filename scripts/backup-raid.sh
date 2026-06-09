#!/usr/bin/env bash
# Backup rsync vers SSD externe (UUID-based mount). Le SSD est remonte en
# read-only apres backup pour limiter les degats en cas de ransomware actif
# sur le host.
#
# Source config /etc/server-backup/backup-raid.env :
#   - BACKUP_RAID_DEVICE_UUID    UUID du device (cf blkid)
#   - BACKUP_RAID_MOUNTPOINT     dossier de mount (cree si absent)
#   - BACKUP_RAID_SOURCE         dossier source a backuper
#
# Note : ce script n'est PAS appele automatiquement par defaut. Il faut
# l'ajouter manuellement a la cron du host (typiquement bi-mensuel).

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

DEVICE="/dev/disk/by-uuid/$BACKUP_RAID_DEVICE_UUID"

LOG_DIR="/var/log/server-backup"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/backup-raid-$(date +%F).log"

log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

cleanup() {
  # Best-effort umount en cas de fail (le SSD reste safe demonte plutot
  # qu'en RW orphan).
  if findmnt -n "$BACKUP_RAID_MOUNTPOINT" >/dev/null 2>&1; then
    umount "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true
  fi
}
trap cleanup ERR

log "=== backup-raid started ==="

# 1. Verifier que le device existe
if ! blkid -s UUID -o value "$DEVICE" >/dev/null 2>&1; then
  log "ERREUR: device $DEVICE introuvable (disque pas branche ?)"
  exit 1
fi
log "UUID $BACKUP_RAID_DEVICE_UUID present : OK"

# 2. Mount ou remount RW si deja en RO
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

# 3. Info espace dispo
log "Espace dispo :"
df -h "$BACKUP_RAID_MOUNTPOINT" | tee -a "$LOG"

# 4. Rsync
log "Rsync $BACKUP_RAID_SOURCE/ -> $BACKUP_RAID_MOUNTPOINT/"
if rsync -av --delete-delay --inplace "$BACKUP_RAID_SOURCE/" "$BACKUP_RAID_MOUNTPOINT/" 2>>"$LOG"; then
  log "Rsync OK"
else
  log "Rsync FAIL"
  umount "$BACKUP_RAID_MOUNTPOINT" 2>/dev/null || true
  exit 1
fi

# 5. Remount RO (safety net contre ransomware actif sur le host)
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
