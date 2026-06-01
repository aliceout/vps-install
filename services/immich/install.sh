#!/usr/bin/env bash
# Install Immich (gestionnaire photos self-hosted, 4 containers).
# Service home server uniquement.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER
#
# Cles attendues dans Infisical CLOUD sous /services/immich/ :
#   - ADDRESS, DOMAIN, PORT       (PORT host expose par le container server)
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - EXTERNAL_LIBRARY            (ex: /media/pi/data/cloud/Alice/files/Photos)
#                                  Dossier "lecture + ecriture" hors Immich,
#                                  typiquement le dossier photos d'un user
#                                  Nextcloud. Immich y lit + modifie (delete,
#                                  retag), mais N'Y UPLOAD PAS (uploads vont
#                                  dans DATA_DIR/upload, voir ci-dessous).
#                                  Un cron quotidien lance occ files:scan sur
#                                  ce path pour que NC voit les modifications.
#   - DB_PASSWORD                 (genere une fois, openssl rand -hex 32)
#   - IMMICH_API_KEY              Optionnel a l'install. Generer depuis l'UI
#                                  Immich -> Account Settings -> API Keys APRES
#                                  le 1er demarrage. Active le cron quotidien
#                                  d'auto-album-from-folder via l'image
#                                  salvoxia/immich-folder-album-creator (cree
#                                  les albums via API a partir des sous-dossiers
#                                  de /library, ne copie rien).
#   - IMMICH_VERSION              (optionnel, defaut "release")
#   - TZ                          (optionnel, defaut "Europe/Paris")
#
# DATA_DIR (uploads via UI/app + ML cache + postgres) auto-cale sur
# /home/$VPS_USER/data/immich, comme les autres services framework.
#
# Containers tournent en UID 33 (www-data) hardcoded pour partager les perms
# avec Nextcloud AIO qui tourne aussi en www-data interne. Sans ca, les
# fichiers crees/modifies par Immich dans EXTERNAL_LIBRARY ne seraient pas
# lisibles par NC.

set -euo pipefail

DATA_DIR="/home/${VPS_USER}/data/${SERVICE_NAME}"
RUNTIME_DIR="/var/lib/services/${SERVICE_NAME}"
RUNTIME_ENV="${RUNTIME_DIR}/runtime.env"
COMPOSE="docker compose -f ${SERVICE_DIR}/docker-compose.yml -p ${SERVICE_NAME} --env-file ${RUNTIME_ENV}"

SCAN_SCRIPT_SRC="${SERVICE_DIR}/scan-photos.sh"
SCAN_SCRIPT_LINK="/usr/local/sbin/immich-scan-photos"
SCAN_CRON="/etc/cron.d/immich-scan-photos"

ALBUM_SCRIPT_SRC="${SERVICE_DIR}/create-albums.sh"
ALBUM_SCRIPT_LINK="/usr/local/sbin/immich-create-albums"
ALBUM_CRON="/etc/cron.d/immich-create-albums"
ALBUM_IMAGE="salvoxia/immich-folder-album-creator:latest"

: "${VPS_USER:?VPS_USER manquant}"

if [[ ! -s "$SECRETS_FILE" ]]; then
  echo "ERREUR: $SECRETS_FILE absent. Verifie /services/${SERVICE_NAME}/ dans Infisical cloud."
  exit 1
fi
# shellcheck disable=SC1090
source "$SECRETS_FILE"

build_runtime_env() {
  : "${ADDRESS:?ADDRESS manquant}"
  : "${PORT:?PORT manquant}"

  # Single Infisical : on utilise l'identite framework via infi-token (cache
  # 10min, --domain auto). Tout est sous /services/immich/ en Cloud.
  local token domain pid env_slug
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "ERREUR: infi-token KO (creds /etc/infisical/* ou connectivite ?)"
    exit 1
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id)"
  env_slug="$(cat /etc/infisical/environment)"

  install -d -m 700 -o root -g "$VPS_USER" "$RUNTIME_DIR"

  # HOST_UID/GID = 33 (www-data) hardcoded : Immich partage les perms avec
  # Nextcloud AIO sur EXTERNAL_LIBRARY. Si tu changes pour pi/1000, NC ne
  # pourra plus lire les fichiers que Immich aura crees/modifies.
  umask 077
  {
    echo "SERVICE_NAME=${SERVICE_NAME}"
    echo "PORT=${PORT}"
    echo "ADDRESS=${ADDRESS}"
    echo "DATA_DIR=${DATA_DIR}"
    echo "UPLOAD_LOCATION=${DATA_DIR}/upload"
    echo "HOST_UID=33"
    echo "HOST_GID=33"
    infisical export \
      --domain="$domain" \
      --projectId="$pid" \
      --env="$env_slug" \
      --path="/services/${SERVICE_NAME}" \
      --format=dotenv \
      --token="$token"
  } > "$RUNTIME_ENV"
  chgrp "$VPS_USER" "$RUNTIME_ENV" || true
  chmod 640 "$RUNTIME_ENV"

  for k in EXTERNAL_LIBRARY DB_PASSWORD; do
    if ! grep -q "^${k}=" "$RUNTIME_ENV"; then
      echo "AVERTISSEMENT: ${k} absent de /services/${SERVICE_NAME}/ dans Infisical Cloud."
    fi
  done
}

# IMMICH_API_KEY est generee depuis l'UI Immich apres le 1er demarrage : pas
# de fail-hard si absente, on saute juste l'install du cron album-create.
has_api_key() {
  grep -qE "^IMMICH_API_KEY=['\"]?[^'\"[:space:]]+" "$RUNTIME_ENV"
}

install_scan_cron() {
  chmod +x "$SCAN_SCRIPT_SRC"
  ln -sf "$SCAN_SCRIPT_SRC" "$SCAN_SCRIPT_LINK"

  cat > "$SCAN_CRON" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 5h00 quotidien - rescan le dossier photos Nextcloud pour qu'il voit les
# modifs ecrites par Immich (NC n'aime pas qu'on ecrive en direct dans son
# data dir sans le prevenir). Wrappe hc-run pour healthcheck.
0 5 * * * root /usr/local/sbin/hc-run immich-scan-photos /usr/local/sbin/immich-scan-photos
EOF
  chmod 644 "$SCAN_CRON"
}

remove_scan_cron() {
  rm -f "$SCAN_CRON"
  rm -f "$SCAN_SCRIPT_LINK"
}

install_album_cron() {
  chmod +x "$ALBUM_SCRIPT_SRC"
  ln -sf "$ALBUM_SCRIPT_SRC" "$ALBUM_SCRIPT_LINK"

  cat > "$ALBUM_CRON" <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# 3h00 quotidien - cree les albums Immich a partir des sous-dossiers de
# /library (la library externe NC). Avant le scan NC de 5h pour que les
# modifs eventuelles d'Immich soient settled. Wrappe hc-run pour healthcheck.
0 3 * * * root /usr/local/sbin/hc-run immich-create-albums /usr/local/sbin/immich-create-albums
EOF
  chmod 644 "$ALBUM_CRON"
}

remove_album_cron() {
  rm -f "$ALBUM_CRON"
  rm -f "$ALBUM_SCRIPT_LINK"
}

case "$ACTION" in
  install|update)
    if getent group docker >/dev/null && ! id -nG "$VPS_USER" | grep -qw docker; then
      usermod -aG docker "$VPS_USER"
    fi

    build_runtime_env

    EXTERNAL_LIBRARY_VALUE="$(grep -E '^EXTERNAL_LIBRARY=' "$RUNTIME_ENV" | cut -d= -f2- | tr -d "'\"")"
    if [[ -z "$EXTERNAL_LIBRARY_VALUE" ]]; then
      echo "ERREUR: EXTERNAL_LIBRARY vide dans le runtime.env. Set-le sous /services/${SERVICE_NAME}/ en Infisical Cloud."
      echo "  Typiquement le path d'un dossier photos Nextcloud, ex:"
      echo "  /media/pi/data/cloud/<user-nc>/files/Photos"
      exit 1
    fi
    if [[ ! -d "$EXTERNAL_LIBRARY_VALUE" ]]; then
      echo "ERREUR: $EXTERNAL_LIBRARY_VALUE n'existe pas. Verifie le path EXTERNAL_LIBRARY."
      exit 1
    fi

    # DATA_DIR : ops data (uploads Immich + ML cache + postgres). Tout en
    # www-data UID 33 (pour partager les perms avec NC sur EXTERNAL_LIBRARY).
    install -d -m 755 -o 33 -g 33 "$DATA_DIR"
    install -d -m 755 -o 33 -g 33 "$DATA_DIR/upload"
    install -d -m 755 -o 33 -g 33 "$DATA_DIR/model-cache"
    # chown -R force : si les dossiers existent deja d'un install precedent
    # avec HOST_UID different (ex: 1000), 'install -d' ne re-chown pas. Le
    # container immich-server (qui tourne en UID 33) se prend alors un EACCES
    # sur upload/encoded-video/.immich et crash-loop. On force ici.
    chown -R 33:33 "$DATA_DIR/upload" "$DATA_DIR/model-cache"
    # Postgres image officielle tourne en UID 999 (interne, separe)
    install -d -m 700 -o 999 -g 999 "$DATA_DIR/postgres"

    # Cron quotidien d'occ files:scan sur le dossier photos NC
    install_scan_cron

    # Cron quotidien d'auto-album-from-folder (uniquement si IMMICH_API_KEY
    # set : la cle est genere depuis l'UI APRES le 1er demarrage Immich).
    if has_api_key; then
      docker pull "$ALBUM_IMAGE" >/dev/null
      install_album_cron
      ALBUM_CRON_INSTALLED=1
    else
      remove_album_cron
      ALBUM_CRON_INSTALLED=0
    fi

    cd "$SERVICE_DIR"
    $COMPOSE pull
    $COMPOSE up -d

    echo
    echo "=== ${SERVICE_NAME} demarre ==="
    echo "URL          : https://${ADDRESS}/"
    echo "Ops data     : ${DATA_DIR} (uploads Immich + ML cache + postgres)"
    echo "Lib externe  : ${EXTERNAL_LIBRARY_VALUE} (dossier photos NC, lu + modifiable)"
    echo "NC scan cron : ${SCAN_CRON} (quotidien 05:00)"
    if [[ "${ALBUM_CRON_INSTALLED:-0}" -eq 1 ]]; then
      echo "Album cron   : ${ALBUM_CRON} (quotidien 03:00, auto-album from folder)"
    else
      echo "Album cron   : non installe (IMMICH_API_KEY absente)."
      echo "               -> UI Immich: Account Settings -> API Keys -> Generer"
      echo "               -> Infisical: ajouter IMMICH_API_KEY sous /services/immich/"
      echo "               -> Relancer 'services install immich --force'"
    fi
    echo
    echo "Premier setup :"
    echo "  1. Visite https://${ADDRESS}/ → cree le compte admin"
    echo "  2. Settings → External Libraries → New Library → import path /library"
    echo
    echo "L'app mobile et les uploads UI atterriront dans Immich (DATA_DIR/upload),"
    echo "pas dans le dossier NC. Le dossier NC reste ta source canonique."
    ;;

  remove)
    cd "$SERVICE_DIR"
    $COMPOSE down 2>/dev/null || true
    remove_scan_cron
    remove_album_cron
    rm -f "$RUNTIME_ENV"
    echo "Stack arretee + crons retires. Data preservee dans DATA_DIR + EXTERNAL_LIBRARY (rm -rf manuel pour purger)."
    ;;

  status)
    cd "$SERVICE_DIR"
    $COMPOSE ps 2>/dev/null || echo "Stack pas demarree."
    [[ -f "$SCAN_CRON" ]] && echo "Cron NC-scan installe: $SCAN_CRON" || echo "Cron NC-scan absent."
    [[ -f "$ALBUM_CRON" ]] && echo "Cron album-create installe: $ALBUM_CRON" || echo "Cron album-create absent."
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
