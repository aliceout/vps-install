#!/usr/bin/env bash
set -euo pipefail

echo "Netdata"
apt-get install -y netdata

cat > /etc/netdata/netdata.conf <<'EOF'
[web]
bind to = 127.0.0.1
EOF

systemctl enable --now netdata
systemctl restart netdata
