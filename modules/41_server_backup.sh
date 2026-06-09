#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone.
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"

# Server-only : skip si HOST_TYPE != server (notamment sur le VPS).
if [[ "$HOST_TYPE" != "server" ]]; then
  echo "Module server-backup : HOST_TYPE='$HOST_TYPE' != server, skip."
  exit 0
fi

echo "Scripts server-backup (server-only)"

# Dependances : borg (backup-borg), rsync (backup-raid), xz + tar (rotating).
apt-get install -y borgbackup rsync xz-utils tar

# --- Migration ancien nom (server-scripts -> server-backup) -----------------
# Anciens hosts ont /etc/server-scripts/, /var/log/server-scripts/. Migration
# one-shot : on bouge si dest absente.
if [[ -d /etc/server-scripts && ! -d /etc/server-backup ]]; then
  echo "Migration /etc/server-scripts -> /etc/server-backup"
  mv /etc/server-scripts /etc/server-backup
fi
if [[ -d /var/log/server-scripts && ! -d /var/log/server-backup ]]; then
  echo "Migration /var/log/server-scripts -> /var/log/server-backup"
  mv /var/log/server-scripts /var/log/server-backup
fi
# Cleanup anciens cron / logrotate / dirs vides
rm -f /etc/cron.d/server-scripts /etc/logrotate.d/server-scripts
rmdir /etc/server-scripts /var/log/server-scripts 2>/dev/null || true

# Layout filesystem
install -d -m 755 /etc/server-backup
install -d -m 755 /var/log/server-backup
install -d /usr/local/sbin

# --- Scripts : symlink depuis le repo (git pull propage les fixes) ----------

# backup-borg : backup rotatif Borg
chmod +x "$ROOT_DIR/scripts/backup-borg.sh"
ln -sf /opt/vps-install/scripts/backup-borg.sh /usr/local/sbin/backup-borg

# nextcloud-snapshot : pg_dump + tar des volumes critiques NC AIO
chmod +x "$ROOT_DIR/scripts/nextcloud-snapshot.sh"
ln -sf /opt/vps-install/scripts/nextcloud-snapshot.sh /usr/local/sbin/nextcloud-snapshot

# backup-rotating : tar.xz daily/weekly/monthly avec rotation auto
chmod +x "$ROOT_DIR/scripts/backup-rotating.sh"
ln -sf /opt/vps-install/scripts/backup-rotating.sh /usr/local/sbin/backup-rotating

# backup-raid : rsync vers SSD externe (UUID-based mount, remount RO apres)
chmod +x "$ROOT_DIR/scripts/backup-raid.sh"
ln -sf /opt/vps-install/scripts/backup-raid.sh /usr/local/sbin/backup-raid

# --- Config par defaut (install-if-absent pour preserver les overrides) -----
for env_name in backup-borg nextcloud-snapshot backup-rotating backup-raid; do
  if [[ ! -f "/etc/server-backup/${env_name}.env" ]]; then
    cp -a "$ROOT_DIR/config/server-backup/${env_name}.env" "/etc/server-backup/${env_name}.env"
    chmod 644 "/etc/server-backup/${env_name}.env"
  fi
done

# --- Logrotate pour tous les logs server-backup -----------------------------
cat > /etc/logrotate.d/server-backup <<'EOF'
/var/log/server-backup/*.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF

# --- Cron : scripts server wrappes hc-run, root -----------------------------
cat > /etc/cron.d/server-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Quotidien 02:00 - rotating tar.xz (daily/weekly/monthly avec rotation auto)
0 2 * * * root /usr/local/sbin/hc-run backup-rotating /usr/local/sbin/backup-rotating

# Quotidien 03:30 - snapshot Nextcloud AIO (pg_dump + tar volumes critiques)
# AVANT le backup borg pour qu'il soit inclus dans l'archive du jour.
30 3 * * * root /usr/local/sbin/hc-run nextcloud-snapshot /usr/local/sbin/nextcloud-snapshot

# Quotidien 04:00 - backup borg rotatif
0 4 * * * root /usr/local/sbin/hc-run backup-borg /usr/local/sbin/backup-borg

# Bi-mensuel 1er et 15 du mois 05:00 - backup rsync vers SSD externe.
# Si pas de SSD branche : le script log l'erreur et exit, pas grave.
0 5 1,15 * * root /usr/local/sbin/hc-run backup-raid /usr/local/sbin/backup-raid
EOF
chmod 644 /etc/cron.d/server-backup
