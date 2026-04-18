#!/usr/bin/env bash
set -euo pipefail

echo "Certbot DNS Infomaniak"

apt-get install -y certbot python3-certbot-dns-infomaniak

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
cp -a "$ROOT_DIR/scripts/certbot-dns.sh" /usr/local/sbin/certbot-dns
chmod +x /usr/local/sbin/certbot-dns
cp -a "$ROOT_DIR/scripts/certbot-request.sh" /usr/local/sbin/certbot-request
chmod +x /usr/local/sbin/certbot-request

# Timer certbot renew (renouvelle automatiquement tous les certs existants)
systemctl enable --now certbot.timer 2>/dev/null || true
