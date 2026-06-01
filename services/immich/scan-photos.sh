#!/usr/bin/env bash
# Rescan le dossier photos Nextcloud pour qu'il voit les fichiers modifies/
# supprimes par Immich (NC n'aime pas qu'on lui ecrive en direct dans son
# data dir sans le prevenir : sans scan, l'UI NC montre encore les fichiers
# supprimes et ignore les modifications).
#
# Derive le path NC-interne (passe a 'occ files:scan') depuis :
#   EXTERNAL_LIBRARY  (host path, ex: /media/pi/data/cloud/Alice/files/Photos)
#   - NEXTCLOUD_DATADIR (lu auto du mastercontainer, ex: /media/pi/data/cloud)
#   = NC_PATH (relatif, ex: /Alice/files/Photos)

set -Eeuo pipefail

RUNTIME_ENV="/var/lib/services/immich/runtime.env"
if [[ ! -f "$RUNTIME_ENV" ]]; then
  echo "ERREUR: $RUNTIME_ENV absent (immich pas installe ?)" >&2
  exit 1
fi

EXTERNAL_LIBRARY="$(grep -E '^EXTERNAL_LIBRARY=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
if [[ -z "$EXTERNAL_LIBRARY" ]]; then
  echo "ERREUR: EXTERNAL_LIBRARY non set dans $RUNTIME_ENV" >&2
  exit 1
fi

# Recupere NEXTCLOUD_DATADIR depuis le mastercontainer (env var injectee
# lors de l'install AIO). Si NC pas up, on bail.
NEXTCLOUD_DATADIR="$(docker inspect nextcloud-aio-mastercontainer \
  --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
  | awk -F= '/^NEXTCLOUD_DATADIR=/ {print $2}')"
if [[ -z "$NEXTCLOUD_DATADIR" ]]; then
  echo "ERREUR: NEXTCLOUD_DATADIR introuvable (nextcloud-aio-mastercontainer up ?)" >&2
  exit 1
fi

# Strip le prefix pour avoir le path NC-interne
case "$EXTERNAL_LIBRARY" in
  "$NEXTCLOUD_DATADIR"/*)
    NC_PATH="${EXTERNAL_LIBRARY#"$NEXTCLOUD_DATADIR"}"
    ;;
  *)
    echo "ERREUR: EXTERNAL_LIBRARY ($EXTERNAL_LIBRARY) n'est pas sous NEXTCLOUD_DATADIR ($NEXTCLOUD_DATADIR)." >&2
    echo "  Le scan NC ne peut pas etre fait : Immich ecrit dans un endroit que NC ne connait pas." >&2
    exit 1
    ;;
esac

echo "[$(date -Is)] occ files:scan --path $NC_PATH"
docker exec --user www-data nextcloud-aio-nextcloud \
  php /var/www/html/occ files:scan --path "$NC_PATH" --quiet
echo "[$(date -Is)] scan termine"
