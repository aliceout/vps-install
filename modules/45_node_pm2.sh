#!/usr/bin/env bash
set -euo pipefail

echo "Node.js + pm2"
NODE_MAJOR="20"
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg

cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main
EOF

apt-get update -y
apt-get install -y nodejs

npm install -g pm2
pm2 startup systemd -u "$VPS_USER" --hp "/home/$VPS_USER"
sudo -u "$VPS_USER" pm2 save