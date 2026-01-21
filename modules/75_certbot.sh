#!/usr/bin/env bash
set -euo pipefail

echo "Certbot DNS Infomaniak"

apt-get install -y certbot python3-certbot-dns-infomaniak

install -d -m 700 /etc/letsencrypt
TOKEN_VALUE="${INFOMANIAK_TOKEN:-CHANGEME}"
cat > /etc/letsencrypt/infomaniak.ini <<EOF
dns_infomaniak_token = ${TOKEN_VALUE}
EOF
chmod 600 /etc/letsencrypt/infomaniak.ini

if [[ ! -f /etc/letsencrypt/domains.ini ]]; then
  cp -a "$ROOT_DIR/config/certbot/domains.ini" /etc/letsencrypt/domains.ini
  if [[ -n "${DOMAIN_MAIN:-}" ]]; then
    printf '%s\n' "${DOMAIN_MAIN}" >> /etc/letsencrypt/domains.ini
  fi
  chmod 600 /etc/letsencrypt/domains.ini
fi

install -d /usr/local/sbin
cp -a "$ROOT_DIR/scripts/certbot-dns.sh" /usr/local/sbin/certbot-dns
chmod +x /usr/local/sbin/certbot-dns
