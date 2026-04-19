#!/usr/bin/env bash
set -euo pipefail

echo "Outils d'audit securite (lynis, rkhunter, debsecan)"

apt-get install -y lynis rkhunter debsecan

install -d -m 755 /var/log/audit

# --- rkhunter ----------------------------------------------------------------
# Config par defaut: envoie des mails root. On redirige plutot dans un log.
if [[ -f /etc/default/rkhunter ]]; then
  sed -i 's|^CRON_DAILY_RUN=.*|CRON_DAILY_RUN="no"|'   /etc/default/rkhunter
  sed -i 's|^CRON_DB_UPDATE=.*|CRON_DB_UPDATE="no"|'   /etc/default/rkhunter
  sed -i 's|^REPORT_EMAIL=.*|REPORT_EMAIL=""|'         /etc/default/rkhunter
fi
# Desactive le cron packagee qui voulait envoyer des mails
chmod -x /etc/cron.daily/rkhunter 2>/dev/null || true

# Mise a jour initiale de la base de signatures rkhunter
rkhunter --update --nocolors 2>/dev/null || true
rkhunter --propupd --nocolors 2>/dev/null || true

# --- debsecan ----------------------------------------------------------------
# Le cron packagee envoie un mail si CVE detectee. On prefere un log.
chmod -x /etc/cron.d/debsecan 2>/dev/null || true
rm -f /etc/cron.d/debsecan  # retire completement, on pilote depuis vps-bootstrap

# --- Notifier Telegram + digest ---------------------------------------------
install -d /usr/local/sbin
chmod +x "$ROOT_DIR/scripts/notify-telegram.sh" \
         "$ROOT_DIR/scripts/audit-digest.sh"
ln -sf /opt/vps-install/scripts/notify-telegram.sh /usr/local/sbin/notify-telegram
ln -sf /opt/vps-install/scripts/audit-digest.sh    /usr/local/sbin/audit-digest

# --- Cron unifie des audits --------------------------------------------------
# On resout le codename Debian maintenant pour le passer a debsecan (qui exige
# --suite des qu'on utilise --only-fixed).
CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-trixie}")"

cat > /etc/cron.d/vps-audit-tools <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Quotidien 05:15 - rkhunter (mise a jour + scan)
15 5 * * * root /usr/bin/rkhunter --update --nocolors >> /var/log/audit/rkhunter-update.log 2>&1 && /usr/bin/rkhunter --cronjob --report-warnings-only --appendlog --nocolors >> /var/log/audit/rkhunter.log 2>&1

# Quotidien 05:30 - debsecan (CVE vs paquets installes, uniquement celles patchables)
30 5 * * * root /usr/bin/debsecan --format=report --suite ${CODENAME} --only-fixed >> /var/log/audit/debsecan.log 2>&1

# Hebdomadaire dimanche 05:45 - lynis audit complet
45 5 * * 0 root /usr/bin/lynis audit system --cronjob --quiet --logfile /var/log/audit/lynis.log --report-file /var/log/audit/lynis-report.dat >/dev/null 2>&1

# Quotidien 08:00 - digest Telegram (silencieux si rien d'interessant)
0 8 * * * root /usr/local/sbin/audit-digest >> /var/log/audit/digest.log 2>&1
EOF
chmod 644 /etc/cron.d/vps-audit-tools

# Logrotate
cat > /etc/logrotate.d/vps-audit-tools <<'EOF'
/var/log/audit/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
}
EOF

# Run initial une fois : snapshot de reference
(
  echo "=== Lynis initial scan $(date -Is) ==="
  lynis audit system --quick --quiet --logfile /var/log/audit/lynis.log --report-file /var/log/audit/lynis-report.dat 2>/dev/null || true
) >/dev/null 2>&1 &
