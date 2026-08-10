#!/usr/bin/env bash
# Service unifie backup : detecte HOST_TYPE et installe la variante adequate.
#
#   - HOST_TYPE=vps     : push rsync (miroir) vers le home server via SSH (creds
#                         dans Infisical /infra/vps/backup/). 4x/jour.
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
  apt-get install -y rsync openssh-client

  # Racine des donnees persistantes : /home/$VPS_USER/data/
  install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 "/home/$VPS_USER/data"

  # Cleanup ancien flow restic (backup-run.sh + backup-restore.sh restic-based)
  # remplaces par backup-rsync.sh + nouveau backup-restore.sh reverse-rsync.
  rm -f /usr/local/sbin/backup-run

  # Symlinks scripts (un git pull = propagation des fix)
  install -d /usr/local/sbin
  chmod +x "$ROOT_DIR/scripts/backup-rsync.sh" "$ROOT_DIR/scripts/backup-restore.sh"
  ln -sf "$ROOT_DIR/scripts/backup-rsync.sh"   /usr/local/sbin/backup-rsync
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

15 0,6,12,18 * * * root /usr/local/sbin/hc-run backup /usr/local/sbin/backup-rsync >> /var/log/vps-backup.log 2>&1
EOF
  chmod 644 /etc/cron.d/vps-backup

  touch /var/log/vps-backup.log
  chmod 640 /var/log/vps-backup.log

  echo "Backup VPS installe (flow rsync simple, historique cote home via Borg)."
  echo "- Cron : 4x/jour (00:15, 06:15, 12:15, 18:15), log /var/log/vps-backup.log"
  echo "- Run : sudo backup-rsync"
  echo "- Restore : sudo backup-restore /home/$VPS_USER/data/<nom>"
}

remove_vps() {
  rm -f /etc/cron.d/vps-backup
  rm -f /etc/logrotate.d/vps-backup
  rm -f /usr/local/sbin/backup-rsync /usr/local/sbin/backup-restore
  # Cleanup ancien symlink restic au cas ou
  rm -f /usr/local/sbin/backup-run
  echo "Backup VPS cron + scripts retires. Le miroir cote home N'EST PAS touche."
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

# Configure la RECEPTION des backups pousses par le VPS (rsync over ssh).
# Opt-in + idempotent : ne fait rien tant que BACKUP_VPS_PUBKEY n'est pas defini
# dans Infisical /infra/server/ (lisible par le home). Pose tout ce qu'on
# configurait a la main -> un home reconstruit recoit les backups sans interv.
#   - BACKUP_VPS_PUBKEY  (requis) pubkey SSH autorisee a pousser (publique, safe)
#   - BACKUP_VPS_DEST    (optionnel, defaut /media/pi/data/vps-mirror)
#   - BACKUP_VPS_USER    (optionnel, defaut backup-vps)
setup_vps_backup_receiver() {
  local token domain pid env_slug
  token="$(infi-token --silent 2>/dev/null || true)"
  if [[ -z "$token" ]]; then
    echo "- Receiver VPS: infi-token KO, skip (relance apres config Infisical)."
    return 0
  fi
  domain="$(infi-token --domain --silent 2>/dev/null || echo 'https://app.infisical.com')"
  pid="$(cat /etc/infisical/project-id 2>/dev/null || true)"
  env_slug="$(cat /etc/infisical/environment 2>/dev/null || true)"

  rfetch() {
    infisical secrets get "$1" \
      --domain="$domain" --projectId="$pid" --env="$env_slug" \
      --path=/infra/server --token="$token" --plain 2>/dev/null || true
  }

  local pubkey dest ruser
  pubkey="$(rfetch BACKUP_VPS_PUBKEY)"
  if [[ -z "$pubkey" ]]; then
    echo "- Receiver VPS: BACKUP_VPS_PUBKEY absent de /infra/server/, reception non configuree (normal si ce home ne recoit pas de backup VPS)."
    return 0
  fi
  dest="$(rfetch BACKUP_VPS_DEST)";  dest="${dest:-/media/pi/data/vps-mirror}"
  ruser="$(rfetch BACKUP_VPS_USER)"; ruser="${ruser:-backup-vps}"

  command -v rrsync >/dev/null 2>&1 || apt-get install -y rsync >/dev/null 2>&1 || true

  # User dedie : shell reel requis (rsync over ssh), password verrouille (cle only)
  if ! id -u "$ruser" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$ruser"
    passwd -l "$ruser" >/dev/null 2>&1 || true
  fi

  # Dossier destination (sous le scope Borg -> l'historique est versionne)
  install -d -o "$ruser" -g "$ruser" -m 750 "$dest"

  # Traversee (x seulement) de chaque parent, sinon $ruser n'atteint pas $dest
  # (ex /media/pi en 700 pi:pi bloque). Pas de +r -> pas de listing possible.
  local p="$dest"
  while :; do
    p="$(dirname "$p")"
    [[ "$p" == "/" || -z "$p" ]] && break
    chmod o+x "$p" 2>/dev/null || true
  done

  # authorized_keys : la cle ne peut QUE rsync (lecture+ecriture) dans $dest
  install -d -o "$ruser" -g "$ruser" -m 700 "/home/${ruser}/.ssh"
  printf 'command="rrsync %s",no-agent-forwarding,no-port-forwarding,no-pty,no-X11-forwarding %s\n' \
    "$dest" "$pubkey" > "/home/${ruser}/.ssh/authorized_keys"
  chown "${ruser}:${ruser}" "/home/${ruser}/.ssh/authorized_keys"
  chmod 600 "/home/${ruser}/.ssh/authorized_keys"

  # sshd : autorise $ruser via un drop-in ADDITIF (AllowUsers est cumulatif ; on
  # ne touche pas 00-vps-hardening.conf gere par le module 10).
  local dropin="/etc/ssh/sshd_config.d/20-backup-vps.conf"
  printf '# Genere par vps-install (service backup) : user de reception du backup VPS.\nAllowUsers %s\n' "$ruser" > "$dropin"
  chmod 644 "$dropin"
  if sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    echo "- Receiver VPS configure : user=$ruser, dest=$dest, sshd autorise (reload OK)."
  else
    rm -f "$dropin"
    echo "AVERTISSEMENT: sshd -t KO apres drop-in receiver -> drop-in retire, sshd inchange." >&2
  fi
}

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
  for s in backup-borg nextcloud-snapshot; do
    chmod +x "$ROOT_DIR/scripts/${s}.sh"
    ln -sf "$ROOT_DIR/scripts/${s}.sh" "/usr/local/sbin/${s}"
  done
  # Cleanup symlinks d'anciens scripts obsoletes (backup-raid / backup-rotating
  # ont ete vires : backup-borg mount-on-demand fait l'equivalent en mieux).
  rm -f /usr/local/sbin/backup-raid /usr/local/sbin/backup-rotating

  # Config par defaut (install-if-absent pour preserver les overrides locaux)
  for env_name in backup-borg nextcloud-snapshot; do
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

# Quotidien 03:30 - snapshot Nextcloud AIO (pg_dump + tar volumes critiques)
# AVANT le backup borg pour qu'il soit inclus dans l'archive du jour.
30 3 * * * root /usr/local/sbin/hc-run nextcloud-snapshot /usr/local/sbin/nextcloud-snapshot

# Quotidien 04:00 - backup borg rotatif (mount-on-demand sur Backup-SSD,
# umount complet apres -> SSD invisible le reste du temps).
0 4 * * * root /usr/local/sbin/hc-run backup-borg /usr/local/sbin/backup-borg
EOF
  chmod 644 /etc/cron.d/server-backup

  # Reception des backups pousses par le VPS (opt-in via /infra/server/BACKUP_VPS_PUBKEY)
  setup_vps_backup_receiver

  echo "Backup server installe."
  echo "- Config : /etc/server-backup/*.env (a editer pour overrider UUID, folders, retention)"
  echo "- Scripts : backup-borg (mount-on-demand), nextcloud-snapshot"
  echo "- Cron : /etc/cron.d/server-backup (2 jobs : 03:30 nc-snapshot, 04:00 borg)"
  echo "- Logs : /var/log/server-backup/"
}

remove_server() {
  rm -f /etc/cron.d/server-backup /etc/logrotate.d/server-backup
  for s in backup-borg nextcloud-snapshot; do
    rm -f "/usr/local/sbin/${s}"
  done
  # Aussi les obsoletes au cas ou ils trainent encore d'une ancienne install
  rm -f /usr/local/sbin/backup-raid /usr/local/sbin/backup-rotating
  echo "Backup server cron + scripts retires. /etc/server-backup/ et /var/log/server-backup/ preserves."
}

status_server() {
  echo "=== Cron server ==="
  [[ -f /etc/cron.d/server-backup ]] && cat /etc/cron.d/server-backup || echo "(pas installe)"
  echo
  echo "=== Scripts deployes ==="
  for s in backup-borg nextcloud-snapshot; do
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
