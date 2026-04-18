#!/usr/bin/env bash
set -euo pipefail

echo "Netdata (kickstart officiel)"

# Nettoie une eventuelle conf packagecloud qui pointe sur une suite non supportee
rm -f /etc/apt/sources.list.d/netdata_netdata.list
rm -f /etc/apt/sources.list.d/netdata_netdata-source.list

if ! command -v netdata >/dev/null 2>&1; then
  # Kickstart officiel : detecte la distro, choisit static/native, gere systemd
  # Flags : non-interactif, canal stable, sans telemetrie
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry
  rm -f /tmp/netdata-kickstart.sh
fi

# Ecoute en local uniquement (le reverse proxy nginx se charge de l'expo HTTPS)
install -d /etc/netdata
cat > /etc/netdata/netdata.conf <<'EOF'
[web]
bind to = 127.0.0.1
EOF

# Desactive la telemetrie anonyme au cas ou le flag aurait rate
touch /etc/netdata/.opt-out-from-anonymous-statistics

systemctl enable --now netdata
systemctl restart netdata

# --- Expose via nginx + basic auth + cert Let's Encrypt wildcard -------------

if [[ -z "${NETDATA_ADRESS:-}" || -z "${NETDATA_DOMAIN:-}" \
   || -z "${NETDATA_AUTH_USER:-}" || -z "${NETDATA_AUTH_PASSWORD:-}" ]]; then
  say_warn "Netdata installe mais pas expose: NETDATA_ADRESS / NETDATA_DOMAIN / NETDATA_AUTH_USER / NETDATA_AUTH_PASSWORD manquants dans Infisical (/services/netdata)."
  exit 0
fi

NETDATA_UPSTREAM="${NETDATA_UPSTREAM:-http://127.0.0.1:19999}"

echo "Htpasswd Netdata (/etc/nginx/.htpasswd-netdata)"
# -B bcrypt, -c crée le fichier, -b prend le password en arg
htpasswd -Bbc /etc/nginx/.htpasswd-netdata "$NETDATA_AUTH_USER" "$NETDATA_AUTH_PASSWORD"
chown root:www-data /etc/nginx/.htpasswd-netdata
chmod 640 /etc/nginx/.htpasswd-netdata

echo "Vhost nginx pour ${NETDATA_ADRESS}"
install -d /etc/nginx/conf
install -d /etc/nginx/certificat
install -d /etc/nginx/sites-enabled

VHOST_DST="/etc/nginx/conf/${NETDATA_ADRESS}.conf"
CERT_DST="/etc/nginx/certificat/${NETDATA_ADRESS}.conf"

cp -a "$ROOT_DIR/nginx/conf/netdata.conf" "$VHOST_DST"
sed -i \
  -e "s|__DOMAIN__|${NETDATA_ADRESS}|g" \
  -e "s|__UPSTREAM__|${NETDATA_UPSTREAM}|g" \
  "$VHOST_DST"

# Include cert pointe sur le wildcard (/etc/letsencrypt/live/<apex>/)
cat > "$CERT_DST" <<EOF
ssl_certificate /etc/letsencrypt/live/${NETDATA_DOMAIN}/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/${NETDATA_DOMAIN}/privkey.pem;
ssl_trusted_certificate /etc/letsencrypt/live/${NETDATA_DOMAIN}/chain.pem;
EOF

ln -sf "$VHOST_DST" "/etc/nginx/sites-enabled/${NETDATA_ADRESS}.conf"

echo "Sync record DNS A chez Infomaniak pour ${NETDATA_ADRESS}"
/usr/local/sbin/infomaniak-dns-sync "$NETDATA_ADRESS" || say_warn "DNS sync echoue (cert pourra ne pas resoudre)."

echo "Requete cert wildcard Let's Encrypt pour ${NETDATA_DOMAIN}"
/usr/local/sbin/certbot-wildcard "$NETDATA_DOMAIN"

nginx -t
systemctl reload nginx
