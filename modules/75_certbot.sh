#!/usr/bin/env bash
set -euo pipefail

echo "Certbot DNS Infomaniak"

# Le paquet Debian python3-certbot-dns-infomaniak est casse (API endpoint
# deprecated qui POST des records qui ne sont jamais publies dans la zone
# live). On installe certbot + le plugin via un venv pip dedie.
apt-get install -y python3-venv python3-pip

# Si l'ancien paquet apt traine, on le vire (nos scripts preferent /usr/local/bin).
apt-get remove -y python3-certbot-dns-infomaniak certbot 2>/dev/null || true

if [[ ! -x /opt/certbot-venv/bin/certbot ]]; then
  python3 -m venv /opt/certbot-venv
fi
/opt/certbot-venv/bin/pip install --upgrade --quiet pip
/opt/certbot-venv/bin/pip install --upgrade --quiet certbot certbot-dns-infomaniak
ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot

install -d -m 700 /etc/letsencrypt

# Email Let's Encrypt (vient de Infisical /vps/_infra/LE_EMAIL)
if [[ -n "${LE_EMAIL:-}" ]]; then
  printf '%s\n' "$LE_EMAIL" > /etc/letsencrypt/email
  chmod 644 /etc/letsencrypt/email
fi

# Token Infomaniak : sync depuis Infisical /vps/_infra/INFOMANIAK_TOKEN
install -d -m 755 /etc/infisical/templates
install -d -m 700 /etc/infisical/agent.d

cat > /etc/infisical/templates/_certbot.tmpl <<EOF
dns_infomaniak_token = {{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/vps/_infra" "INFOMANIAK_TOKEN" }} {{ .Value }}{{- end }}
EOF

cat > /etc/infisical/agent.d/_certbot.yaml <<'EOF'
  - source-path: /etc/infisical/templates/_certbot.tmpl
    destination-path: /etc/letsencrypt/infomaniak.ini
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

echo "Attente synchro token Infomaniak depuis Infisical..."
i=0
while [[ ! -s /etc/letsencrypt/infomaniak.ini ]] && (( i < 60 )); do
  sleep 1
  i=$((i+1))
done
if [[ ! -s /etc/letsencrypt/infomaniak.ini ]]; then
  echo "AVERTISSEMENT: /etc/letsencrypt/infomaniak.ini non genere. Verifie que /vps/_infra/INFOMANIAK_TOKEN existe dans Infisical (${INFISICAL_ENV:-prod})."
fi
chmod 600 /etc/letsencrypt/infomaniak.ini 2>/dev/null || true

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
