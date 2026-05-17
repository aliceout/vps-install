#!/usr/bin/env bash
# nextcloud-snapshot : backup propre de Nextcloud AIO via stop + tar + start.
#
# Stratégie : on stoppe tous les containers AIO (sans toucher au mastercontainer
# dont la config orchestre le reste), on tar les volumes au repos (donc cohérents,
# pas de risque de corruption), on redémarre tout. Downtime ~2 min, à 3h du mat.
#
# Auto-decouverte des containers et volumes -> si AIO ajoute Talk/Collabora/etc.
# plus tard, c'est inclus automatiquement.
#
# Exclusion automatique du volume nextcloud_aio_nextcloud_data si NEXTCLOUD_DATADIR
# pointe sur un bind mount externe (cas typique : fichiers users sur un autre disque).
#
# Restore : install AIO from scratch, stop tout, untar chaque archive dans son
# volume (/var/lib/docker/volumes/<vol>/_data/), start AIO. Voir manifest.txt
# pour les versions exactes d'images au moment du snapshot.

set -Eeuo pipefail

CONFIG_FILE="/etc/server-scripts/nextcloud-snapshot.env"
LOG_DIR="/var/log/server-scripts"
LOG_FILE="$LOG_DIR/nextcloud-snapshot.log"

install -d -m 755 "$LOG_DIR"
exec >>"$LOG_FILE" 2>&1
echo
echo "=== $(date -Is) nextcloud-snapshot (stop-and-tar) ==="

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERREUR: $CONFIG_FILE introuvable" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONFIG_FILE"

: "${OUTPUT_DIR:?OUTPUT_DIR manquant dans $CONFIG_FILE}"
: "${AIO_VOLUMES_DIR:=/var/lib/docker/volumes}"
: "${WAIT_TIMEOUT:=120}"
: "${EXTRA_EXCLUDE_VOLUMES:=}"

install -d -m 750 "$OUTPUT_DIR"

# --- Discovery ---------------------------------------------------------------
# On capture l'etat AVANT toute modification : la liste des containers qu'on
# devra redemarrer = ceux qui tournent maintenant.
RUNNING_CONTAINERS=()
while IFS= read -r c; do
  RUNNING_CONTAINERS+=("$c")
done < <(docker ps --filter 'name=nextcloud-aio' --format '{{.Names}}' | sort)

if [[ ${#RUNNING_CONTAINERS[@]} -eq 0 ]]; then
  echo "ERREUR: aucun container nextcloud-aio-* running, abort." >&2
  exit 1
fi
echo "Containers detectes (${#RUNNING_CONTAINERS[@]}) : ${RUNNING_CONTAINERS[*]}"

# Volumes : tous nextcloud_aio_*, moins ceux qu'on exclut explicitement.
ALL_VOLUMES=()
while IFS= read -r v; do
  ALL_VOLUMES+=("$v")
done < <(docker volume ls --filter 'name=nextcloud_aio_' --format '{{.Name}}' | sort)

# Detection NEXTCLOUD_DATADIR : si bind mount externe, on n'inclut pas le
# volume "data" parce qu'il est probablement vide ou contient juste un lien.
# (Si c'est un volume docker classique, on l'inclut comme les autres.)
EXCLUDE_VOLUMES=()
DATADIR="$(docker inspect nextcloud-aio-mastercontainer \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | awk -F= '/^NEXTCLOUD_DATADIR=/ {print $2}')"
if [[ -n "$DATADIR" && "$DATADIR" != /var/lib/docker/volumes/* ]]; then
  EXCLUDE_VOLUMES+=("nextcloud_aio_nextcloud_data")
  echo "NEXTCLOUD_DATADIR=$DATADIR (externe) -> skip volume nextcloud_aio_nextcloud_data"
fi
# Append les exclusions custom de la config
for v in $EXTRA_EXCLUDE_VOLUMES; do
  EXCLUDE_VOLUMES+=("$v")
done

# --- Trap : restart d'urgence si on crash entre stop et start ---------------
_restart_emergency() {
  echo "  -> trap: tentative de restart des containers (etat indetermine)"
  for c in "${RUNNING_CONTAINERS[@]}"; do
    docker start "$c" >/dev/null 2>&1 || echo "     fail restart $c"
  done
}
trap '_restart_emergency; exit 1' INT TERM ERR

# --- Stop --------------------------------------------------------------------
echo "Stop des containers..."
# Stop en bloc, Docker gere les SIGTERM en parallele
docker stop --time 30 "${RUNNING_CONTAINERS[@]}" >/dev/null

# Wait jusqu'a tout effectivement stopped (paranoia : un container peut etre
# en train de finir sa pile de connexions)
elapsed=0
while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
  still=$(docker ps --filter 'name=nextcloud-aio' -q | wc -l)
  [[ "$still" -eq 0 ]] && break
  sleep 2
  elapsed=$((elapsed + 2))
done
if [[ "$still" -ne 0 ]]; then
  echo "ERREUR: $still containers encore running apres ${WAIT_TIMEOUT}s" >&2
  exit 1
fi
echo "  -> tous stopped"

# --- Tar les volumes ---------------------------------------------------------
echo "Tar des volumes vers $OUTPUT_DIR..."
TAR_OK=1
for vol in "${ALL_VOLUMES[@]}"; do
  # Skip si dans la liste d'exclusion
  skip=0
  for excl in "${EXCLUDE_VOLUMES[@]}"; do
    [[ "$vol" == "$excl" ]] && skip=1 && break
  done
  if [[ $skip -eq 1 ]]; then
    echo "  -> $vol (skip, exclu)"
    continue
  fi
  vol_path="$AIO_VOLUMES_DIR/$vol/_data"
  if [[ ! -d "$vol_path" ]]; then
    echo "  -> $vol (skip, $vol_path inexistant)"
    continue
  fi
  TMP="$OUTPUT_DIR/${vol}.tar.gz.new"
  if tar -czf "$TMP" -C "$AIO_VOLUMES_DIR/$vol" _data 2>>"$LOG_FILE"; then
    mv "$TMP" "$OUTPUT_DIR/${vol}.tar.gz"
    echo "  -> $vol ($(du -h "$OUTPUT_DIR/${vol}.tar.gz" | awk '{print $1}'))"
  else
    rm -f "$TMP"
    echo "  -> ERREUR tar $vol" >&2
    TAR_OK=0
  fi
done

# --- Restart -----------------------------------------------------------------
# On enleve le trap d'urgence : on va restart proprement.
trap - INT TERM ERR

echo "Restart des containers..."
docker start "${RUNNING_CONTAINERS[@]}" >/dev/null

# Wait pour healthcheck (best-effort : on attend que tous soient au moins
# running, sans exiger healthy parce que postgres + nextcloud peuvent prendre
# 1-2min a passer healthy apres restart)
elapsed=0
while [[ $elapsed -lt $WAIT_TIMEOUT ]]; do
  not_running=$(comm -23 \
    <(printf '%s\n' "${RUNNING_CONTAINERS[@]}" | sort -u) \
    <(docker ps --filter 'name=nextcloud-aio' --filter status=running --format '{{.Names}}' | sort -u) \
    | wc -l)
  [[ "$not_running" -eq 0 ]] && break
  sleep 2
  elapsed=$((elapsed + 2))
done
if [[ "$not_running" -eq 0 ]]; then
  echo "  -> tous restart OK"
else
  echo "  -> AVERTISSEMENT: $not_running containers pas encore running apres ${WAIT_TIMEOUT}s"
fi

# --- Manifest ----------------------------------------------------------------
{
  echo "# Nextcloud AIO snapshot generated $(date -Is) on $(hostname)"
  echo "# Strategy: stop-and-tar"
  echo
  echo "## NEXTCLOUD_DATADIR (hors snapshot si bind mount externe)"
  echo "${DATADIR:-(non set)}"
  echo
  echo "## Volumes exclus"
  printf '  - %s\n' "${EXCLUDE_VOLUMES[@]:-(aucun)}"
  echo
  echo "## Container images au moment du snapshot"
  docker ps --filter 'name=nextcloud-aio' --format '{{.Names}}\t{{.Image}}' | sort
  echo
  echo "## Archives"
  cd "$OUTPUT_DIR" && ls -la --time-style=long-iso *.tar.gz 2>/dev/null
} > "$OUTPUT_DIR/manifest.txt"
chmod 640 "$OUTPUT_DIR"/*.tar.gz "$OUTPUT_DIR/manifest.txt" 2>/dev/null || true

if [[ "$TAR_OK" -ne 1 ]]; then
  echo "ERREUR: un ou plusieurs tar ont echoue" >&2
  exit 1
fi

echo "=== $(date -Is) snapshot termine OK ==="
