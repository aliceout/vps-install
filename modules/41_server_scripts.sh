#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone.
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"

# Server-only : skip si HOST_TYPE != server (notamment sur le VPS).
if [[ "$HOST_TYPE" != "server" ]]; then
  echo "Module server-scripts : HOST_TYPE='$HOST_TYPE' != server, skip."
  exit 0
fi

echo "Scripts server-only"

# Dependances des scripts server (borg pour backup-borg)
apt-get install -y borgbackup

# Layout filesystem
install -d -m 755 /etc/server-scripts
install -d -m 755 /var/log/server-scripts
install -d /usr/local/sbin

# --- backup-borg ------------------------------------------------------------
# Le script reste dans le repo et on pose juste un symlink. Comme ca git pull
# propage les fixes sans reinstall.
chmod +x "$ROOT_DIR/scripts/backup-borg.sh"
ln -sf /opt/vps-install/scripts/backup-borg.sh /usr/local/sbin/backup-borg

# Config par defaut UNIQUEMENT si absente, pour preserver les overrides locaux
# (paths/folders specifiques au host).
if [[ ! -f /etc/server-scripts/backup-borg.env ]]; then
  cp -a "$ROOT_DIR/config/server-scripts/backup-borg.env" /etc/server-scripts/backup-borg.env
  chmod 644 /etc/server-scripts/backup-borg.env
fi

# --- nextcloud-snapshot -----------------------------------------------------
# Snapshot leger Nextcloud AIO (pg_dump + tar des volumes critiques uniquement)
# pour permettre une restauration sans dependre du backup borg integre d'AIO,
# qui copie aussi les fichiers users (souvent 100+ GB inutiles).
chmod +x "$ROOT_DIR/scripts/nextcloud-snapshot.sh"
ln -sf /opt/vps-install/scripts/nextcloud-snapshot.sh /usr/local/sbin/nextcloud-snapshot

if [[ ! -f /etc/server-scripts/nextcloud-snapshot.env ]]; then
  cp -a "$ROOT_DIR/config/server-scripts/nextcloud-snapshot.env" /etc/server-scripts/nextcloud-snapshot.env
  chmod 644 /etc/server-scripts/nextcloud-snapshot.env
fi

# --- Logrotate pour tous les logs server-scripts ----------------------------
cat > /etc/logrotate.d/server-scripts <<'EOF'
/var/log/server-scripts/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF

# --- Cron : scripts server-only wrappes hc-run, root ------------------------
cat > /etc/cron.d/server-scripts <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Quotidien 03:30 - snapshot Nextcloud AIO (pg_dump + tar volumes critiques)
# AVANT le backup borg pour qu'il soit inclus dans l'archive du jour.
30 3 * * * root /usr/local/sbin/hc-run nextcloud-snapshot /usr/local/sbin/nextcloud-snapshot

# Quotidien 04:00 - backup borg rotatif
0 4 * * * root /usr/local/sbin/hc-run backup-borg /usr/local/sbin/backup-borg
EOF
chmod 644 /etc/cron.d/server-scripts
