#!/usr/bin/env bash
set -euo pipefail

echo "ZRAM swap"
apt-get install -y zram-tools

cat > /etc/default/zramswap <<'EOF'
# Simple zram swap config
ENABLED=true
# % of RAM to use for zram
PERCENT=50
# Swap priority
PRIORITY=100
EOF

systemctl restart zramswap || true