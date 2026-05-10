#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte ROOT_DIR/VPS_USER).
ROOT_DIR="${ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
VPS_USER="${VPS_USER:-$(cat /etc/infisical/vps-user 2>/dev/null || true)}"

echo "Nginx + Certbot"
apt-get install -y nginx python3-certbot-nginx

install -d /etc/nginx/include
install -d /etc/nginx/conf
install -d /etc/nginx/conf.d
install -d /etc/nginx/certificat

# /var/www accessible en ecriture par $VPS_USER (les hook scripts des
# webhooks y clonent les repos + y build)
install -d -o "$VPS_USER" -g "$VPS_USER" -m 755 /var/www

# Includes (repo -> /etc/nginx/...)
cp -a "$ROOT_DIR/nginx/include/." /etc/nginx/include/
cp -a "$ROOT_DIR/nginx/conf/common.conf" /etc/nginx/conf.d/common.conf

# Charge les vhosts de /etc/nginx/conf/ (evite le jeu sites-available/sites-enabled).
# Les vhosts eux-memes sont deployes par scripts/service.sh lors de l'install
# de chaque service (services/<nom>/nginx.conf).
cat > /etc/nginx/conf.d/00-vhosts.conf <<'EOF'
include /etc/nginx/conf/*.conf;
EOF

# Desactive le vhost par defaut de Debian et nettoie l'ancien pattern
rm -f /etc/nginx/sites-enabled/default
rm -rf /etc/nginx/sites-enabled

nginx -t
systemctl enable --now nginx
systemctl reload nginx
