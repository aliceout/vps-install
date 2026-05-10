#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte ROOT_DIR).
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echo "Outils d'audit securite (lynis, aide, debsecan)"

apt-get install -y lynis aide debsecan

install -d -m 755 /var/log/audit

# --- Cleanup rkhunter (remplace par AIDE) -----------------------------------
# rkhunter upstream est abandonne (2022), mirrors morts, signature-based
# detection obsolete face aux rootkits modernes. AIDE prend le relai pour la
# file integrity ; CrowdSec couvre la threat detection live.
if dpkg -l rkhunter 2>/dev/null | grep -q '^ii'; then
  apt-get purge -y rkhunter
fi
rm -f /etc/cron.daily/rkhunter
rm -f /var/log/audit/rkhunter.log /var/log/audit/rkhunter.log.*

# --- AIDE -------------------------------------------------------------------
# File integrity: snapshot local des hash de tous les binaires/configs critiques.
# Au scan quotidien, diff vs baseline -> on voit ce qui a change. La baseline
# est regeneree chaque dimanche apres le digest, pour absorber les apt upgrade
# de la semaine sans accumuler de faux positifs.

# Le cron Debian par defaut envoie les diffs par mail a root. On disable au
# profit de notre cron qui logue dans /var/log/audit/aide.log.
chmod -x /etc/cron.daily/aide 2>/dev/null || true

# Initialise la baseline si absente. aideinit prend 5-15min sur un VPS typique
# (hash recursif de /usr, /etc, /bin...) -> background pour ne pas bloquer
# le bootstrap.
if [[ ! -f /var/lib/aide/aide.db ]]; then
  echo "AIDE: initialisation de la baseline en background (~10min)..."
  (
    aideinit -y -f >/dev/null 2>&1 || true
    [[ -f /var/lib/aide/aide.db.new ]] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db
  ) >/dev/null 2>&1 &
fi

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

# Quotidien 05:15 - AIDE check (diff vs baseline). aide --check renvoie != 0
# des qu'il y a des diffs -> on swallow l'exit code, le digest fait le tri.
15 5 * * * root /usr/bin/aide --check > /var/log/audit/aide.log 2>&1 || true

# Quotidien 05:30 - debsecan (CVE vs paquets installes, uniquement celles patchables)
30 5 * * * root /usr/bin/debsecan --format=report --suite ${CODENAME} --only-fixed >> /var/log/audit/debsecan.log 2>&1

# Hebdomadaire dimanche 05:45 - lynis audit complet
45 5 * * 0 root /usr/bin/lynis audit system --cronjob --quiet --logfile /var/log/audit/lynis.log --report-file /var/log/audit/lynis-report.dat >/dev/null 2>&1

# Hebdomadaire dimanche 06:30 - regen baseline AIDE (apres digest hebdo,
# absorbe les apt upgrade de la semaine pour eviter les faux positifs)
30 6 * * 0 root bash -c '/usr/bin/aide --update >/dev/null 2>&1; [ -f /var/lib/aide/aide.db.new ] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db'

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

# Run initial une fois : snapshot de reference lynis
(
  echo "=== Lynis initial scan $(date -Is) ==="
  lynis audit system --quick --quiet --logfile /var/log/audit/lynis.log --report-file /var/log/audit/lynis-report.dat 2>/dev/null || true
) >/dev/null 2>&1 &
