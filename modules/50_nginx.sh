#!/usr/bin/env bash
set -euo pipefail

echo "Nginx + Certbot"
apt-get install -y nginx python3-certbot-nginx

install -d /etc/nginx/include
install -d /etc/nginx/conf
install -d /etc/nginx/conf.d
install -d /etc/nginx/certificat

# Includes (repo -> /etc/nginx/...)
cp -a "$ROOT_DIR/nginx/include/." /etc/nginx/include/
cp -a "$ROOT_DIR/nginx/conf/common.conf" /etc/nginx/conf.d/common.conf
cp -a "$ROOT_DIR/nginx/certificat/certbot-template.conf" /etc/nginx/certificat/certbot-template.conf

# Charge les vhosts de /etc/nginx/conf/ (evite le jeu sites-available/sites-enabled)
cat > /etc/nginx/conf.d/00-vhosts.conf <<'EOF'
include /etc/nginx/conf/*.conf;
EOF

# Desactive le vhost par defaut de Debian et nettoie l'ancien pattern
rm -f /etc/nginx/sites-enabled/default
rm -rf /etc/nginx/sites-enabled

create_vhost() {
  local domain="$1"
  local upstream="$2"
  local dst="/etc/nginx/conf/${domain}.conf"
  local cert="/etc/nginx/certificat/${domain}.conf"

  cp -a "$ROOT_DIR/nginx/conf/template.conf" "$dst"
  cp -a /etc/nginx/certificat/certbot-template.conf "$cert"
  sed -i \
    -e "s|__DOMAIN__|${domain}|g" \
    -e "s|__UPSTREAM__|${upstream}|g" \
    "$dst"
  sed -i -e "s|__DOMAIN__|${domain}|g" "$cert"
}

if [[ -n "${DOMAIN_MAIN:-}" && -n "${PROXY_UPSTREAM:-}" ]]; then
  create_vhost "$DOMAIN_MAIN" "$PROXY_UPSTREAM"
fi

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "Certbot: tu le lanceras apres avoir pointe le DNS:"
echo "  sudo certbot --nginx -d <domaine> -m <email> --agree-tos --redirect"
