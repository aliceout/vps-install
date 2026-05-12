#!/usr/bin/env bash
set -euo pipefail

echo "Infisical: persist creds + agent systemd"

# Fallback quand le module tourne standalone
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Pre-requis: CLI deja installe par bootstrap.sh, creds deja prompted et auth validee.
# Variables attendues en env:
#   INFISICAL_ADDRESS, INFISICAL_PROJECT_ID, INFISICAL_ENV
#   INFISICAL_CLIENT_ID, INFISICAL_CLIENT_SECRET

install -d -m 700 -o root -g root /etc/infisical
install -d -m 700 -o root -g root /etc/infisical/agent.d
install -d -m 755 -o root -g root /etc/infisical/templates
install -d -m 700 -o root -g root /etc/secrets
install -d -m 755 -o root -g root /var/lib/vps-install
install -d -m 755 -o root -g root /var/lib/vps-install/installed

umask 077
printf '%s' "$INFISICAL_CLIENT_ID"     > /etc/infisical/client-id
printf '%s' "$INFISICAL_CLIENT_SECRET" > /etc/infisical/client-secret
chmod 600 /etc/infisical/client-id /etc/infisical/client-secret
chown root:root /etc/infisical/client-id /etc/infisical/client-secret

# Project ID + env + address : pas sensibles mais necessaires a tous les
# templates ET aux scripts CLI qui font 'infisical secrets get'. L'address
# notamment doit etre persiste sinon les scripts tapent app.infisical.com
# par defaut au lieu du self-hosted (bug silencieux quand on a un Infisical
# perso).
printf '%s' "$INFISICAL_PROJECT_ID" > /etc/infisical/project-id
printf '%s' "$INFISICAL_ENV"        > /etc/infisical/environment
printf '%s' "$INFISICAL_ADDRESS"    > /etc/infisical/address
chmod 644 /etc/infisical/project-id /etc/infisical/environment /etc/infisical/address

# Nom du user non-root persiste aussi (scripts/service.sh et les install.sh
# des services en ont besoin pour les perms et les systemd units)
printf '%s' "$VPS_USER" > /etc/infisical/vps-user
chmod 644 /etc/infisical/vps-user

cat > /etc/infisical/agent.base.yaml <<EOF
infisical:
  address: ${INFISICAL_ADDRESS}
  exit-after-auth: false

auth:
  type: universal-auth
  config:
    client-id: /etc/infisical/client-id
    client-secret: /etc/infisical/client-secret
    remove_client_secret_on_read: false

sinks: []

templates:
EOF
chmod 600 /etc/infisical/agent.base.yaml

cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
chmod 600 /etc/infisical/agent.yaml

cat > /etc/systemd/system/infisical-agent.service <<'EOF'
[Unit]
Description=Infisical Agent (secrets sync)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/infisical agent --config /etc/infisical/agent.yaml
Restart=on-failure
RestartSec=5s
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable infisical-agent.service

# Helper infi-token : cache de token + injection automatique de --domain pour
# tous les scripts (cron-frequents : certbot-refresh-creds, notify-telegram,
# backup-*) afin d'eviter le rate-limit Infisical et le piege du domain par
# defaut (app.infisical.com) quand on est self-hosted.
chmod +x "$ROOT_DIR/scripts/infi-token.sh"
install -d /usr/local/sbin
ln -sf /opt/vps-install/scripts/infi-token.sh /usr/local/sbin/infi-token

echo "Infisical agent configure (demarrera au 1er template ajoute par service.sh)."
