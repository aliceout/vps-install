#!/usr/bin/env bash
# Log retention : journald + logrotate plafonnes a 48h max.
#
# Idempotent : on pose des drop-ins, pas d'edit en place des fichiers Debian
# (qui generent un conffile prompt au prochain apt upgrade). Re-execution sans
# danger.
set -euo pipefail

echo "Log retention : journald 2 jours + logrotate maxage 2"

# --- journald ---------------------------------------------------------------
# Drop-in dans /etc/systemd/journald.conf.d/. systemd merge automatiquement.
# MaxRetentionSec=2day  -> efface les enregistrements plus vieux que 2 jours
# SystemMaxUse=500M     -> cap dur sur la taille totale du journal persistant
# ForwardToSyslog=no    -> evite la duplication journald + /var/log/syslog
#                          (les logs fichiers ont leur propre retention)
install -d -m 755 /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-vps-retention.conf <<'EOF'
[Journal]
MaxRetentionSec=2day
SystemMaxUse=500M
ForwardToSyslog=no
EOF
chmod 644 /etc/systemd/journald.conf.d/99-vps-retention.conf

systemctl restart systemd-journald

# Purge immediate des enregistrements deja anciens (sinon le cap kick in
# uniquement sur les nouveaux ecrits, et le vieux residuel reste).
journalctl --vacuum-time=2d >/dev/null 2>&1 || true

# --- logrotate --------------------------------------------------------------
# Fichier 'global' dans /etc/logrotate.d/ : les directives sans braces
# s'appliquent globalement et override les defaults de /etc/logrotate.conf.
# Le prefixe '00-' garantit qu'on est lu en premier (les per-file configs
# qui viennent apres peuvent toujours override pour leurs fichiers).
#
# daily         -> rotation tous les jours (au lieu de weekly par defaut)
# rotate 1      -> garde 1 fichier rotated max (current + 1 rotated = 2 jours)
# maxage 2      -> ceinture/bretelles : efface tout rotated > 2 jours, peu
#                  importe rotate N (utile si une per-file config met rotate 14)
cat > /etc/logrotate.d/00-vps-defaults <<'EOF'
# Pose par vps-install (modules/27_log_retention.sh). Plafonne tous les
# logs fichiers a 48h max. Les per-file configs dans /etc/logrotate.d/
# peuvent override pour leurs fichiers specifiques si besoin.
daily
rotate 1
maxage 2
EOF
chmod 644 /etc/logrotate.d/00-vps-defaults

# Force un cycle logrotate maintenant pour appliquer immediatement la
# nouvelle politique aux fichiers deja anciens.
logrotate -f /etc/logrotate.conf >/dev/null 2>&1 || true

echo "Log retention configure :"
echo "  - journald : MaxRetentionSec=2day, SystemMaxUse=500M"
echo "  - logrotate : daily + rotate 1 + maxage 2 (drop-in 00-vps-defaults)"
