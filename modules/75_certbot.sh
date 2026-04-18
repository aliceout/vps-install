#!/usr/bin/env bash
set -euo pipefail

echo "Certbot DNS Infomaniak"

# Le paquet upstream certbot-dns-infomaniak utilise l'API v1 Infomaniak qui est
# deprecated : les POST de nouveaux records DNS ne sont jamais publies sur les
# NS autoritatifs (bug cote Infomaniak). On installe :
# - certbot officiel depuis PyPI
# - notre fork du plugin qui cible l'API v2 (publie correctement)
# Ref: https://github.com/Infomaniak/certbot-dns-infomaniak/issues/47
apt-get install -y python3-venv python3-pip git

# Vire l'eventuel ancien paquet apt qui trainerait.
apt-get remove -y python3-certbot-dns-infomaniak certbot 2>/dev/null || true

if [[ ! -x /opt/certbot-venv/bin/certbot ]]; then
  python3 -m venv /opt/certbot-venv
fi
/opt/certbot-venv/bin/pip install --upgrade --quiet pip
/opt/certbot-venv/bin/pip install --upgrade --quiet certbot
/opt/certbot-venv/bin/pip install --upgrade --quiet \
  git+https://github.com/aliceout/certbot-dns-infomaniak.git
ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot

install -d -m 700 /etc/letsencrypt

# Token Infomaniak + email Let's Encrypt : synces en continu par l'agent
# Infisical (pas de copie one-shot, l'agent les maintient a jour).
install -d -m 755 /etc/infisical/templates
install -d -m 700 /etc/infisical/agent.d

cat > /etc/infisical/templates/_certbot.tmpl <<EOF
dns_infomaniak_token = {{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/vps/_infra" "INFOMANIAK_TOKEN" }} {{ .Value }}{{- end }}
EOF

cat > /etc/infisical/templates/_le_email.tmpl <<EOF
{{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/vps/_infra" "CERTBOT_EMAIL" }}{{ .Value }}{{- end }}
EOF

cat > /etc/infisical/agent.d/_certbot.yaml <<'EOF'
  - source-path: /etc/infisical/templates/_certbot.tmpl
    destination-path: /etc/letsencrypt/infomaniak.ini
    config:
      polling-interval: 300s
  - source-path: /etc/infisical/templates/_le_email.tmpl
    destination-path: /etc/letsencrypt/email
    config:
      polling-interval: 300s
EOF
chmod 600 /etc/infisical/agent.d/_certbot.yaml

cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
shopt -s nullglob
for f in /etc/infisical/agent.d/*.yaml; do
  cat "$f" >> /etc/infisical/agent.yaml
done
shopt -u nullglob
chmod 600 /etc/infisical/agent.yaml

systemctl enable --now infisical-agent.service
systemctl restart infisical-agent.service

echo "Attente synchro infomaniak.ini + email depuis Infisical..."
i=0
while { [[ ! -s /etc/letsencrypt/infomaniak.ini ]] || [[ ! -s /etc/letsencrypt/email ]]; } && (( i < 60 )); do
  sleep 1
  i=$((i+1))
done
if [[ ! -s /etc/letsencrypt/infomaniak.ini ]]; then
  echo "AVERTISSEMENT: /etc/letsencrypt/infomaniak.ini non genere. Verifie que /vps/_infra/INFOMANIAK_TOKEN existe dans Infisical (${INFISICAL_ENV:-prod})."
fi
if [[ ! -s /etc/letsencrypt/email ]]; then
  echo "AVERTISSEMENT: /etc/letsencrypt/email non genere. Verifie que /vps/_infra/CERTBOT_EMAIL existe dans Infisical (${INFISICAL_ENV:-prod})."
fi
chmod 600 /etc/letsencrypt/infomaniak.ini 2>/dev/null || true
chmod 644 /etc/letsencrypt/email 2>/dev/null || true

# Fichier domains.ini pour les renouvelements en masse (wildcards)
if [[ ! -f /etc/letsencrypt/domains.ini ]]; then
  cp -a "$ROOT_DIR/config/certbot/domains.ini" /etc/letsencrypt/domains.ini
  if [[ -n "${DOMAIN_MAIN:-}" ]]; then
    printf '%s\n' "${DOMAIN_MAIN}" >> /etc/letsencrypt/domains.ini
  fi
  chmod 600 /etc/letsencrypt/domains.ini
fi

install -d /usr/local/sbin
# Symlinks vers /opt/vps-install/scripts/ : un git pull sur le repo propage
# automatiquement les fix sans avoir a redeployer manuellement.
chmod +x "$ROOT_DIR/scripts/certbot-dns.sh" \
         "$ROOT_DIR/scripts/certbot-request.sh" \
         "$ROOT_DIR/scripts/certbot-wildcard.sh" \
         "$ROOT_DIR/scripts/infomaniak-dns-sync.sh"
ln -sf /opt/vps-install/scripts/certbot-dns.sh         /usr/local/sbin/certbot-dns
ln -sf /opt/vps-install/scripts/certbot-request.sh     /usr/local/sbin/certbot-request
ln -sf /opt/vps-install/scripts/certbot-wildcard.sh    /usr/local/sbin/certbot-wildcard
ln -sf /opt/vps-install/scripts/infomaniak-dns-sync.sh /usr/local/sbin/infomaniak-dns-sync

# Log rotation pour le sync DNS
cat > /etc/logrotate.d/infomaniak-dns-sync <<'EOF'
/var/log/infomaniak-dns-sync.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF

# Cron: sync auto-heal des records A toutes les heures
cat > /etc/cron.d/infomaniak-dns-sync <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root /usr/local/sbin/infomaniak-dns-sync >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/infomaniak-dns-sync

# Timer certbot renew (renouvelle automatiquement tous les certs existants)
systemctl enable --now certbot.timer 2>/dev/null || true
