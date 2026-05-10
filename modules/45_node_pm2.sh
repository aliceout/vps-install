#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte VPS_USER).
VPS_USER="${VPS_USER:-$(cat /etc/infisical/vps-user 2>/dev/null || true)}"

echo "Node.js + pm2"
NODE_MAJOR="20"
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
chmod a+r /usr/share/keyrings/nodesource.gpg

cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF

apt-get update -y
apt-get install -y nodejs

npm install -g pm2

# pm2 startup genere l'unit systemd (en root, base sur $VPS_USER)
pm2 startup systemd -u "$VPS_USER" --hp "/home/$VPS_USER"

# npm -g deploie parfois node_modules/pm2 en 0700 -> les users non-root se
# prennent "permission denied" sur le binaire. On force r+X (X = exec only sur
# dirs ou fichiers deja exec) sur tout l'arbre et on reaffirme +x sur la cli.
chmod -R a+rX /usr/lib/node_modules/pm2 2>/dev/null || true
chmod a+rx /usr/lib/node_modules/pm2/bin/pm2 2>/dev/null || true
chmod a+rx /usr/bin/pm2 2>/dev/null || true

# pm2 save cree un dump vide exploitable par pm2 resurrect au reboot.
# runuser (plus robuste que sudo -u pour les binaires npm globaux).
runuser -u "$VPS_USER" -- pm2 save || true