#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte ROOT_DIR).
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

echo "Outils d'audit securite (lynis, aide) + Healthchecks"

apt-get install -y lynis aide

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

# --- Cleanup debsecan (redondant avec unattended-upgrades) ------------------
# unattended-upgrades patche deja les CVE quotidiennement. Le rapport debsecan
# liste surtout les CVE sans fix dispo (bruit) et les CVE deja patchees mais
# non-rebooted -> peu actionnable en pratique.
if dpkg -l debsecan 2>/dev/null | grep -q '^ii'; then
  apt-get purge -y debsecan
fi
rm -f /etc/cron.d/debsecan
rm -f /var/log/audit/debsecan.log /var/log/audit/debsecan.log.*

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

# --- Healthchecks template (Infisical agent) --------------------------------
# Sync /infra/shared/HEALTHCHECKS_PING_KEY -> /etc/secrets/healthchecks.env
# Le wrapper hc-run lit cette cle pour pinger https://hc-ping.com/<key>/<slug>.
# Si le secret n'est pas defini cote Infisical, le fichier sera vide et hc-run
# fera un no-op (exec direct sans ping) -> safe pour le bootstrap initial.

INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-$(cat /etc/infisical/project-id 2>/dev/null || true)}"
INFISICAL_ENV="${INFISICAL_ENV:-$(cat /etc/infisical/environment 2>/dev/null || true)}"
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"
if [[ -z "$INFISICAL_PROJECT_ID" || -z "$INFISICAL_ENV" || -z "$HOST_TYPE" ]]; then
  echo "AVERTISSEMENT: INFISICAL_PROJECT_ID/ENV/HOST_TYPE introuvable, skip Healthchecks setup."
else
  install -d -m 755 /etc/infisical/templates
  install -d -m 700 /etc/infisical/agent.d
  install -d -m 700 /etc/secrets

  # HEALTHCHECKS_PING_KEY est sous /infra/<host_type>/ (per-host) car chaque
  # host a son propre projet HC -> propre cle de ping.
  # HEALTHCHECKS_URL_BASE est sous /infra/shared/ : meme valeur pour tous les
  # hosts (= URL de l'instance self-hosted, ou defaut hc-ping.com si pas set).
  cat > /etc/infisical/templates/_healthchecks.tmpl <<EOF
HEALTHCHECKS_PING_KEY={{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/infra/${HOST_TYPE}" "HEALTHCHECKS_PING_KEY" }}{{ .Value }}{{- end }}
HEALTHCHECKS_URL_BASE={{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/infra/shared" "HEALTHCHECKS_URL_BASE" }}{{ .Value }}{{- end }}
EOF

  cat > /etc/infisical/agent.d/_healthchecks.yaml <<'EOF'
  - source-path: /etc/infisical/templates/_healthchecks.tmpl
    destination-path: /etc/secrets/healthchecks.env
    config:
      polling-interval: 300s
EOF
  chmod 600 /etc/infisical/agent.d/_healthchecks.yaml

  # Reconstruit agent.yaml depuis base + tous les fragments dans agent.d/
  if [[ -f /etc/infisical/agent.base.yaml ]]; then
    cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
    shopt -s nullglob
    for f in /etc/infisical/agent.d/*.yaml; do
      cat "$f" >> /etc/infisical/agent.yaml
    done
    shopt -u nullglob
    chmod 600 /etc/infisical/agent.yaml
    systemctl enable --now infisical-agent.service 2>/dev/null || true
    systemctl restart infisical-agent.service 2>/dev/null || true
  fi
fi

# --- hc-run : wrapper Healthchecks pour les crons ---------------------------
chmod +x "$ROOT_DIR/scripts/hc-run.sh"
ln -sf /opt/vps-install/scripts/hc-run.sh /usr/local/sbin/hc-run

# --- hc-ping : ping direct (sans exec) pour les services systemd ------------
# Utilise par les template units hc-ping@.service / hc-ping-fail@.service,
# wires via OnSuccess=/OnFailure= dans des drop-ins service.d/.
chmod +x "$ROOT_DIR/scripts/hc-ping.sh"
ln -sf /opt/vps-install/scripts/hc-ping.sh /usr/local/sbin/hc-ping

# Template units reutilisables : OnSuccess=hc-ping@<slug>.service ping le
# slug en mode "ok", OnFailure=hc-ping-fail@<slug>.service ping en "fail".
# Le %i de systemd = la partie apres le @ dans le nom du service.
cat > /etc/systemd/system/hc-ping@.service <<'EOF'
[Unit]
Description=Healthchecks success ping for %i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hc-ping %i ok
EOF

cat > /etc/systemd/system/hc-ping-fail@.service <<'EOF'
[Unit]
Description=Healthchecks fail ping for %i

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/hc-ping %i fail
EOF

# Drop-in pour apt-daily-upgrade.service : ping Healthchecks au resultat
# de chaque cycle unattended-upgrades. Si le service n'a pas tourne du tout
# (VPS down, timer cassee), aucun ping -> Healthchecks alerte "late/down"
# apres le grace period configure cote dashboard.
install -d -m 755 /etc/systemd/system/apt-daily-upgrade.service.d
cat > /etc/systemd/system/apt-daily-upgrade.service.d/healthchecks.conf <<'EOF'
[Unit]
OnSuccess=hc-ping@apt-upgrade.service
OnFailure=hc-ping-fail@apt-upgrade.service
EOF

systemctl daemon-reload

# --- Notifier Telegram + digest ---------------------------------------------
install -d /usr/local/sbin
chmod +x "$ROOT_DIR/scripts/notify-telegram.sh" \
         "$ROOT_DIR/scripts/audit-digest.sh"
ln -sf /opt/vps-install/scripts/notify-telegram.sh /usr/local/sbin/notify-telegram
ln -sf /opt/vps-install/scripts/audit-digest.sh    /usr/local/sbin/audit-digest

# --- Cron unifie des audits --------------------------------------------------
# Toutes les commandes sont wrappees avec hc-run pour pinger Healthchecks
# (no-op si la cle n'est pas encore configuree).
cat > /etc/cron.d/audit-tools <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Quotidien 05:15 - AIDE check (|| true car diffs renvoient != 0, normal)
15 5 * * * root /usr/local/sbin/hc-run aide-check bash -c '/usr/bin/aide --check > /var/log/audit/aide.log 2>&1 || true'

# Hebdomadaire dimanche 05:45 - lynis audit complet
45 5 * * 0 root /usr/local/sbin/hc-run lynis-audit /usr/bin/lynis audit system --cronjob --quiet --logfile /var/log/audit/lynis.log --report-file /var/log/audit/lynis-report.dat

# Hebdomadaire dimanche 06:30 - regen baseline AIDE (absorbe les apt upgrade
# de la semaine pour eviter les faux positifs)
30 6 * * 0 root /usr/local/sbin/hc-run aide-update bash -c '/usr/bin/aide --update >/dev/null 2>&1; [ -f /var/lib/aide/aide.db.new ] && mv /var/lib/aide/aide.db.new /var/lib/aide/aide.db'

# Quotidien 08:00 - digest Telegram (silencieux si rien d'interessant)
0 8 * * * root /usr/local/sbin/hc-run audit-digest /usr/local/sbin/audit-digest >> /var/log/audit/digest.log 2>&1
EOF
# Cleanup ancien nom (rename vps-audit-tools -> audit-tools, tourne sur VPS + Server)
rm -f /etc/cron.d/vps-audit-tools /etc/logrotate.d/vps-audit-tools

chmod 644 /etc/cron.d/audit-tools

# Logrotate
cat > /etc/logrotate.d/audit-tools <<'EOF'
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
