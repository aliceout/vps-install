#!/usr/bin/env bash
# Service unifie backup : detecte HOST_TYPE et installe la variante adequate.
#
#   - HOST_TYPE=vps     : push restic vers le home server via SSH (creds dans
#                         Infisical /services/backup/). 4x/jour.
#   - HOST_TYPE=server  : backup local (borg rotatif + tar.xz rotating + raid
#                         sur SSD externe + snapshot Nextcloud AIO). Tout en
#                         local sur le home server, pas de creds reseau.
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

set -euo pipefail

: "${VPS_USER:?VPS_USER manquant}"

ROOT_DIR="${ROOT_DIR:-/opt/vps-install}"
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"

# ============================================================================
# Variante VPS : push restic vers home server
# ============================================================================
install_vps() {
  apt-get install -y restic openssh-client

  # Racine des donnees persistantes : /home/$VPS_USER/data/
  install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "/home/$VPS_USER/data"

  # Symlinks scripts (un git pull = propagation des fix)
  install -d /usr/local/sbin
  chmod +x "$ROOT_DIR/scripts/backup-run.sh" "$ROOT_DIR/scripts/backup-restore.sh"
  ln -sf "$ROOT_DIR/scripts/backup-run.sh"     /usr/local/sbin/backup-run
  ln -sf "$ROOT_DIR/scripts/backup-restore.sh" /usr/local/sbin/backup-restore

  cat > /etc/logrotate.d/vps-backup <<'EOF'
/var/log/vps-backup.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF

  # Cron : 4x/jour, horaires decales pour eviter apt-daily etc.
  cat > /etc/cron.d/vps-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 0,6,12,18 * * * root /usr/local/sbin/hc-run backup /usr/local/sbin/backup-run >> /var/log/vps-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/vps-backup

  touch /var/log/vps-backup.log
  chmod 640 /var/log/vps-backup.log

  echo "Backup VPS installe."
  echo "- Cron : 4x/jour (00:15, 06:15, 12:15, 18:15), log /var/log/vps-backup.log"
  echo "- Run : sudo backup-run"
  echo "- Restore : sudo backup-restore /var/lib/services/<nom>"
}

remove_vps() {
  rm -f /etc/cron.d/vps-backup
  rm -f /etc/logrotate.d/vps-backup
  rm -f /usr/local/sbin/backup-run /usr/local/sbin/backup-restore
  echo "Backup VPS cron + scripts retires. Le repo restic cote home N'EST PAS touche."
}

status_vps() {
  echo "=== Cron VPS ==="
  [[ -f /etc/cron.d/vps-backup ]] && cat /etc/cron.d/vps-backup || echo "(pas installe)"
  echo
  echo "=== Derniere execution ==="
  tail -20 /var/log/vps-backup.log 2>/dev/null || echo "(pas de log)"
}

# ============================================================================
# Variante server : backup local (borg + rotating + raid + nc-snapshot)
# ============================================================================
install_server() {
  apt-get install -y borgbackup rsync xz-utils tar

  # Migration ancien nom (server-scripts -> server-backup) si applicable
  if [[ -d /etc/server-scripts && ! -d /etc/server-backup ]]; then
    echo "Migration /etc/server-scripts -> /etc/server-backup"
    mv /etc/server-scripts /etc/server-backup
  fi
  if [[ -d /var/log/server-scripts && ! -d /var/log/server-backup ]]; then
    echo "Migration /var/log/server-scripts -> /var/log/server-backup"
    mv /var/log/server-scripts /var/log/server-backup
  fi
  rm -f /etc/cron.d/server-scripts /etc/logrotate.d/server-scripts
  rmdir /etc/server-scripts /var/log/server-scripts 2>/dev/null || true

  install -d -m 755 /etc/server-backup
  install -d -m 755 /var/log/server-backup
  install -d /usr/local/sbin

  # Symlinks scripts
  for s in backup-borg nextcloud-snapshot backup-rotating backup-raid; do
    chmod +x "$ROOT_DIR/scripts/${s}.sh"
    ln -sf "$ROOT_DIR/scripts/${s}.sh" "/usr/local/sbin/${s}"
  done

  # Config par defaut (install-if-absent pour preserver les overrides locaux)
  for env_name in backup-borg nextcloud-snapshot backup-rotating backup-raid; do
    if [[ ! -f "/etc/server-backup/${env_name}.env" ]]; then
      cp -a "$ROOT_DIR/config/server-backup/${env_name}.env" "/etc/server-backup/${env_name}.env"
      chmod 644 "/etc/server-backup/${env_name}.env"
    fi
  done

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

  cat > /etc/cron.d/server-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Quotidien 02:00 - rotating tar.xz (daily/weekly/monthly + rotation auto)
0 2 * * * root /usr/local/sbin/hc-run backup-rotating /usr/local/sbin/backup-rotating

# Quotidien 03:30 - snapshot Nextcloud AIO (pg_dump + tar volumes critiques)
# AVANT le backup borg pour qu'il soit inclus dans l'archive du jour.
30 3 * * * root /usr/local/sbin/hc-run nextcloud-snapshot /usr/local/sbin/nextcloud-snapshot

# Quotidien 04:00 - backup borg rotatif
0 4 * * * root /usr/local/sbin/hc-run backup-borg /usr/local/sbin/backup-borg

# Bi-mensuel 1er et 15 du mois 05:00 - backup rsync vers SSD externe.
0 5 1,15 * * root /usr/local/sbin/hc-run backup-raid /usr/local/sbin/backup-raid
EOF
  chmod 644 /etc/cron.d/server-backup

  echo "Backup server installe."
  echo "- Config : /etc/server-backup/*.env (a editer pour overrider FOLDERS, UUIDs, etc.)"
  echo "- Scripts : backup-borg, nextcloud-snapshot, backup-rotating, backup-raid"
  echo "- Cron : /etc/cron.d/server-backup (4 jobs : 02:00, 03:30, 04:00, raid bi-mensuel)"
  echo "- Logs : /var/log/server-backup/"
}

remove_server() {
  rm -f /etc/cron.d/server-backup /etc/logrotate.d/server-backup
  for s in backup-borg nextcloud-snapshot backup-rotating backup-raid; do
    rm -f "/usr/local/sbin/${s}"
  done
  echo "Backup server cron + scripts retires. /etc/server-backup/ et /var/log/server-backup/ preserves."
}

status_server() {
  echo "=== Cron server ==="
  [[ -f /etc/cron.d/server-backup ]] && cat /etc/cron.d/server-backup || echo "(pas installe)"
  echo
  echo "=== Scripts deployes ==="
  for s in backup-borg nextcloud-snapshot backup-rotating backup-raid; do
    if [[ -L "/usr/local/sbin/${s}" ]]; then
      echo "  $s -> $(readlink -f "/usr/local/sbin/${s}")"
    else
      echo "  $s : (manquant)"
    fi
  done
  echo
  echo "=== Logs recents ==="
  ls -la /var/log/server-backup/ 2>/dev/null | tail -10 || echo "(pas de logs)"
}

# ============================================================================
# Dispatcher
# ============================================================================
case "$HOST_TYPE" in
  vps)    flow=vps ;;
  server) flow=server ;;
  *)
    echo "ERREUR: HOST_TYPE='$HOST_TYPE' inconnu. Doit etre 'vps' ou 'server'." >&2
    echo "  Verifie /etc/infisical/host-type." >&2
    exit 1
    ;;
esac

case "$ACTION" in
  install|update) "install_${flow}" ;;
  remove)         "remove_${flow}"  ;;
  status)         "status_${flow}"  ;;
  *)              echo "Action inconnue: $ACTION"; exit 1 ;;
esac
