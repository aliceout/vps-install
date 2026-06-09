#!/usr/bin/env bash
# Backup borg multi-folders.
#
# Lit la config depuis /etc/server-backup/backup-borg.env (pose par le
# module 41_server_scripts.sh, surchargeable par l'admin du host).
# Boucle sur les dossiers definis, run "borg create" pour chacun, et exit
# 1 si au moins une sauvegarde a echoue (compteur d'erreurs global) -> le
# wrapper hc-run remonte alors un fail sur Healthchecks.
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
if [[ -z "${BORG_FOLDERS+x}" ]] || (( ${#BORG_FOLDERS[@]} == 0 )); then
  echo "ERREUR: BORG_FOLDERS vide ou non defini dans $CONFIG_FILE" >&2
  exit 2
fi

install -d -m 755 "$(dirname "$LOG_FILE")"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

errors=0

log "=== Backup borg started (repo=$BORG_REPO) ==="

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

log "=== Backup borg ended (errors=$errors) ==="

[[ $errors -eq 0 ]]
