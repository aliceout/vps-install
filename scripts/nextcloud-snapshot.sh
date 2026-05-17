#!/usr/bin/env bash
# nextcloud-snapshot : prend un snapshot leger de Nextcloud AIO pour permettre
# une restauration sans dependre du backup borg integre d'AIO.
#
# Outputs (dans $OUTPUT_DIR, defini dans /etc/server-scripts/nextcloud-snapshot.env) :
#   - db.sql.gz            : pg_dump complet de la DB Nextcloud
#   - aio-config.tar.gz    : volume nextcloud_aio_mastercontainer (config AIO + BORG_PASSPHRASE)
#   - nc-config.tar.gz     : volume nextcloud_aio_nextcloud (config.php, apps, themes)
#   - manifest.txt         : timestamps + tailles + versions des images en cours
#
# Le script ne backup PAS les fichiers users (NEXTCLOUD_DATADIR pointe sur un
# disque bind-monte, geres separement). Il ne backup PAS non plus apache/redis/
# imaginary/collabora (regenerables a l'install).
#
# Restauration : voir docs/nextcloud-restore.md (resume dans le manifest.txt).

set -Eeuo pipefail

CONFIG_FILE="/etc/server-scripts/nextcloud-snapshot.env"
LOG_DIR="/var/log/server-scripts"
LOG_FILE="$LOG_DIR/nextcloud-snapshot.log"

install -d -m 755 "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1
echo
echo "=== $(date -Is) nextcloud-snapshot ==="

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERREUR: $CONFIG_FILE introuvable" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${OUTPUT_DIR:?OUTPUT_DIR manquant dans $CONFIG_FILE}"
: "${POSTGRES_CONTAINER:?POSTGRES_CONTAINER manquant}"
: "${POSTGRES_USER:?POSTGRES_USER manquant}"
: "${POSTGRES_DB:?POSTGRES_DB manquant}"
: "${AIO_VOLUMES_DIR:=/var/lib/docker/volumes}"
: "${VOLUMES_TO_BACKUP:=nextcloud_aio_mastercontainer:aio-config nextcloud_aio_nextcloud:nc-config}"

install -d -m 750 "$OUTPUT_DIR"

# Verifie que le container postgres tourne
if ! docker ps --filter "name=${POSTGRES_CONTAINER}" --filter status=running -q | grep -q .; then
  echo "ERREUR: container ${POSTGRES_CONTAINER} ne tourne pas." >&2
  exit 1
fi

# 1. pg_dump compresse a la volee
echo "  -> pg_dump ${POSTGRES_DB} (user=${POSTGRES_USER}) ..."
TMP_DB="$OUTPUT_DIR/db.sql.gz.new"
if ! docker exec "$POSTGRES_CONTAINER" pg_dump \
      -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
      --no-owner --no-privileges --clean --if-exists 2>>"$LOG_FILE" \
      | gzip -9 > "$TMP_DB"; then
  rm -f "$TMP_DB"
  echo "ERREUR: pg_dump KO" >&2
  exit 1
fi
mv "$TMP_DB" "$OUTPUT_DIR/db.sql.gz"
echo "     OK ($(du -h "$OUTPUT_DIR/db.sql.gz" | awk '{print $1}'))"

# 2. Tar des volumes critiques. Format VOLUMES_TO_BACKUP: "vol_name:archive_name ..."
echo "  -> tar volumes critiques ..."
for entry in $VOLUMES_TO_BACKUP; do
  vol="${entry%:*}"
  archive="${entry#*:}"
  vol_path="$AIO_VOLUMES_DIR/$vol/_data"
  if [[ ! -d "$vol_path" ]]; then
    echo "     AVERTISSEMENT: $vol_path absent, skip"
    continue
  fi
  TMP_ARCHIVE="$OUTPUT_DIR/${archive}.tar.gz.new"
  if ! tar -czf "$TMP_ARCHIVE" -C "$AIO_VOLUMES_DIR/$vol" _data 2>>"$LOG_FILE"; then
    rm -f "$TMP_ARCHIVE"
    echo "ERREUR: tar $vol KO" >&2
    exit 1
  fi
  mv "$TMP_ARCHIVE" "$OUTPUT_DIR/${archive}.tar.gz"
  echo "     OK $archive ($(du -h "$OUTPUT_DIR/${archive}.tar.gz" | awk '{print $1}'))"
done

# 3. Manifest avec versions des images pour la traçabilite
{
  echo "# Nextcloud AIO snapshot generated $(date -Is) on $(hostname)"
  echo
  echo "## Files"
  cd "$OUTPUT_DIR" && ls -la --time-style=long-iso *.gz 2>/dev/null
  echo
  echo "## Container images"
  docker ps --filter 'name=nextcloud-aio' --format '{{.Names}}\t{{.Image}}' 2>/dev/null \
    | sort
  echo
  echo "## NEXTCLOUD_DATADIR (fichiers users, hors snapshot)"
  docker inspect nextcloud-aio-mastercontainer --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep -E '^NEXTCLOUD_DATADIR=' || echo "(non set, defaut volume)"
} > "$OUTPUT_DIR/manifest.txt"

chmod 640 "$OUTPUT_DIR"/*.gz "$OUTPUT_DIR/manifest.txt" 2>/dev/null || true

echo "=== $(date -Is) snapshot termine ==="
echo "Output : $OUTPUT_DIR"
ls -la --time-style=long-iso "$OUTPUT_DIR"
