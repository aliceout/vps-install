#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE, VPS_USER

: "${VPS_USER:?VPS_USER manquant}"

# VPS-only : ce service push les backups VERS le home server via SSH+restic
# (les creds HOME_SSH_HOST/RESTIC_REPOSITORY/etc. sont sous Infisical Cloud
# /services/backup/, normalement settes que pour les hosts VPS). Sur un host
# 'server' c'est non-sens (il faudrait qu'il se backup vers lui-meme).
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"
if [[ "$HOST_TYPE" != "vps" ]]; then
  echo "Service backup : HOST_TYPE='$HOST_TYPE' != vps, skip (service VPS-only)."
  echo "  Le home server utilise services/server-backup pour ses backups locaux."
  exit 0
fi

case "$ACTION" in
  install|update)
    apt-get install -y restic openssh-client

    # Racine des donnees persistantes : /home/$VPS_USER/data/
    # Chaque service met ses volumes dans un sous-dossier.
    install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "/home/$VPS_USER/data"

    # Deploie les scripts via symlinks (un git pull = propagation des fix)
    install -d /usr/local/sbin
    chmod +x "/opt/vps-install/scripts/backup-run.sh" \
             "/opt/vps-install/scripts/backup-restore.sh"
    ln -sf /opt/vps-install/scripts/backup-run.sh     /usr/local/sbin/backup-run
    ln -sf /opt/vps-install/scripts/backup-restore.sh /usr/local/sbin/backup-restore

    # Log rotation
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

    # Cron : 4x/jour. Horaires decales de 15min pour ne pas cogner l'apt-daily
    # et autres cron a la ronde.
    cat > /etc/cron.d/vps-backup <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

15 0,6,12,18 * * * root /usr/local/sbin/hc-run backup /usr/local/sbin/backup-run >> /var/log/vps-backup.log 2>&1
EOF
    chmod 644 /etc/cron.d/vps-backup

    touch /var/log/vps-backup.log
    chmod 640 /var/log/vps-backup.log

    echo "Backup service installe."
    echo "- Cron: 4x/jour (00:15, 06:15, 12:15, 18:15), log /var/log/vps-backup.log"
    echo "- Run a la demande: sudo backup-run"
    echo "- Restore: sudo backup-restore /var/lib/services/<nom>"
    ;;

  remove)
    rm -f /etc/cron.d/vps-backup
    rm -f /etc/logrotate.d/vps-backup
    rm -f /usr/local/sbin/backup-run /usr/local/sbin/backup-restore
    echo "Backup cron + scripts retires. Le repo restic cote home n'est PAS touche."
    ;;

  status)
    echo "=== Cron ==="
    [[ -f /etc/cron.d/vps-backup ]] && cat /etc/cron.d/vps-backup || echo "(pas installe)"
    echo
    echo "=== Derniere execution ==="
    tail -20 /var/log/vps-backup.log 2>/dev/null || echo "(pas de log)"
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
