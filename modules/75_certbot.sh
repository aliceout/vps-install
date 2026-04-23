#!/usr/bin/env bash
set -euo pipefail

echo "Certbot (DNS Infomaniak + OVH) multi-provider"

# Plugins :
# - certbot officiel (PyPI)
# - fork certbot-dns-infomaniak utilisant l'API v2 (l'upstream v1 est casse)
#   ref: https://github.com/Infomaniak/certbot-dns-infomaniak/issues/47
# - certbot-dns-ovh officiel (maintenu par certbot, pas un fork)
apt-get install -y python3-venv python3-pip git

apt-get remove -y python3-certbot-dns-infomaniak python3-certbot-dns-ovh certbot 2>/dev/null || true

if [[ ! -x /opt/certbot-venv/bin/certbot ]]; then
  python3 -m venv /opt/certbot-venv
fi
/opt/certbot-venv/bin/pip install --upgrade --quiet pip
/opt/certbot-venv/bin/pip install --upgrade --quiet certbot
/opt/certbot-venv/bin/pip install --upgrade --quiet \
  git+https://github.com/aliceout/certbot-dns-infomaniak.git
/opt/certbot-venv/bin/pip install --upgrade --quiet certbot-dns-ovh
ln -sf /opt/certbot-venv/bin/certbot /usr/local/bin/certbot

install -d -m 700 /etc/letsencrypt
install -d -m 755 /etc/certbot
install -d -m 700 /etc/certbot/creds
install -d -m 700 /etc/certbot/creds/infomaniak
install -d -m 700 /etc/certbot/creds/ovh
touch /etc/certbot/providers.conf
chmod 644 /etc/certbot/providers.conf

# Agent templates Infisical :
#   - /etc/letsencrypt/email : email Let's Encrypt (inchange, au meme endroit
#     que le flow historique)
#   - /etc/letsencrypt/infomaniak.ini : TOKEN legacy depuis /vps/_infra (laisse
#     en place le temps de la migration vers /vps/certbot/infomaniak/<name>).
#     Disparaitra quand tous les services auront migre.
install -d -m 755 /etc/infisical/templates
install -d -m 700 /etc/infisical/agent.d

cat > /etc/infisical/templates/_certbot_email.tmpl <<EOF
{{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/vps/_infra" "CERTBOT_EMAIL" }}{{ .Value }}{{- end }}
EOF

cat > /etc/infisical/templates/_certbot_legacy.tmpl <<EOF
dns_infomaniak_token = {{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/vps/_infra" "INFOMANIAK_TOKEN" }} {{ .Value }}{{- end }}
EOF

cat > /etc/infisical/agent.d/_certbot.yaml <<'EOF'
  - source-path: /etc/infisical/templates/_certbot_email.tmpl
    destination-path: /etc/letsencrypt/email
    config:
      polling-interval: 300s
  - source-path: /etc/infisical/templates/_certbot_legacy.tmpl
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

echo "Attente synchro email + legacy ini..."
i=0
while { [[ ! -s /etc/letsencrypt/email ]] \
     || [[ ! -s /etc/letsencrypt/infomaniak.ini ]]; } && (( i < 60 )); do
  sleep 1
  i=$((i+1))
done
if [[ ! -s /etc/letsencrypt/email ]]; then
  echo "AVERTISSEMENT: /etc/letsencrypt/email non genere. Verifie /vps/_infra/CERTBOT_EMAIL."
fi
chmod 600 /etc/letsencrypt/infomaniak.ini 2>/dev/null || true
chmod 644 /etc/letsencrypt/email 2>/dev/null || true

# Fichier domains.ini : liste les apex a renouveler en bulk.
# certbot-wildcard ajoute automatiquement les apex qu'il gere.
if [[ ! -f /etc/letsencrypt/domains.ini ]]; then
  cp -a "$ROOT_DIR/config/certbot/domains.ini" /etc/letsencrypt/domains.ini
  chmod 600 /etc/letsencrypt/domains.ini
fi

# Helpers multi-provider : les symlinks vers /opt/vps-install/scripts/ font
# que git pull propage les fixes sans reinstall.
install -d /usr/local/sbin
chmod +x "$ROOT_DIR/scripts/certbot-dns.sh" \
         "$ROOT_DIR/scripts/certbot-request.sh" \
         "$ROOT_DIR/scripts/certbot-wildcard.sh" \
         "$ROOT_DIR/scripts/certbot-refresh-creds.sh" \
         "$ROOT_DIR/scripts/dns-sync.sh"
ln -sf /opt/vps-install/scripts/certbot-dns.sh            /usr/local/sbin/certbot-dns
ln -sf /opt/vps-install/scripts/certbot-request.sh        /usr/local/sbin/certbot-request
ln -sf /opt/vps-install/scripts/certbot-wildcard.sh       /usr/local/sbin/certbot-wildcard
ln -sf /opt/vps-install/scripts/certbot-refresh-creds.sh  /usr/local/sbin/certbot-refresh-creds
ln -sf /opt/vps-install/scripts/dns-sync.sh               /usr/local/sbin/dns-sync
# Alias legacy : pointe sur dns-sync. Les crons existants continuent de marcher.
ln -sf /opt/vps-install/scripts/dns-sync.sh               /usr/local/sbin/infomaniak-dns-sync

# Pre-hook certbot renew : regen les ini de creds depuis Infisical avant
# chaque renewal. Handle la rotation des tokens cote Infisical sans
# redeployer manuellement.
install -d -m 755 /etc/letsencrypt/renewal-hooks/pre
ln -sf /usr/local/sbin/certbot-refresh-creds \
       /etc/letsencrypt/renewal-hooks/pre/refresh-creds

# Run un premier refresh maintenant, pour que /etc/certbot/creds/ soit pret
# si des services veulent emettre des certs avec le nouveau systeme.
/usr/local/sbin/certbot-refresh-creds >/dev/null 2>&1 || true

# Log rotation pour dns-sync
cat > /etc/logrotate.d/dns-sync <<'EOF'
/var/log/dns-sync.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
# Legacy log file (si ancien infomaniak-dns-sync.log existe encore)
/var/log/infomaniak-dns-sync.log {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    delaycompress
}
EOF
rm -f /etc/logrotate.d/infomaniak-dns-sync

# Cron: sync auto-heal des records A toutes les heures
cat > /etc/cron.d/dns-sync <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
17 * * * * root /usr/local/sbin/dns-sync >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/dns-sync
rm -f /etc/cron.d/infomaniak-dns-sync

# Timer certbot renew
systemctl enable --now certbot.timer 2>/dev/null || true
