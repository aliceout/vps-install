#!/usr/bin/env bash
set -euo pipefail

echo "Infisical: persist creds + agent systemd"

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

# Project ID + env : pas sensibles mais necessaires a tous les templates
printf '%s' "$INFISICAL_PROJECT_ID" > /etc/infisical/project-id
printf '%s' "$INFISICAL_ENV"        > /etc/infisical/environment
chmod 644 /etc/infisical/project-id /etc/infisical/environment

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

echo "Infisical agent configure (demarrera au 1er template ajoute par service.sh)."
