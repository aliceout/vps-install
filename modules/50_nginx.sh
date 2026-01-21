#!/usr/bin/env bash
set -euo pipefail

echo "Nginx + Certbot"
apt-get install -y nginx python3-certbot-nginx

install -d /etc/nginx/include
install -d /etc/nginx/conf
install -d /etc/nginx/conf.d
install -d /etc/nginx/certificat
install -d /etc/nginx/sites-enabled

# Includes (repo -> /etc/nginx/...)
cp -a "$ROOT_DIR/nginx/include/." /etc/nginx/include/
cp -a "$ROOT_DIR/nginx/conf/common.conf" /etc/nginx/conf.d/common.conf
cp -a "$ROOT_DIR/nginx/certificat/certbot-template.conf" /etc/nginx/certificat/certbot-template.conf

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
  ln -sf "$dst" "/etc/nginx/sites-enabled/${domain}.conf"
}

if [[ -n "${DOMAIN_MAIN:-}" && -n "${PROXY_UPSTREAM:-}" ]]; then
  create_vhost "$DOMAIN_MAIN" "$PROXY_UPSTREAM"
fi

if [[ -n "${NETDATA_DOMAIN:-}" && -n "${NETDATA_UPSTREAM:-}" ]]; then
  create_vhost "$NETDATA_DOMAIN" "$NETDATA_UPSTREAM"
fi
rm -f /etc/nginx/sites-enabled/default || true

nginx -t
systemctl enable --now nginx
systemctl reload nginx

echo "Certbot: tu le lanceras apres avoir pointe le DNS:"
echo "  sudo certbot --nginx -d <domaine> -m <email> --agree-tos --redirect"