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

# Catch-all default server : sans ca, une requete vers un host non-matche
# (apex de domaine sans vhost, ex alyss.cc, ou scan d'IP brute) est servie
# par le 1er vhost charge alphabetiquement -> fuite de contenu d'un autre
# service. Ici on attrape tout le non-matche et on rejette proprement :
#   - HTTP 80  -> return 444 (ferme la connexion sans repondre)
#   - HTTPS 443 -> ssl_reject_handshake (rejette le TLS si le SNI matche aucun
#                  vhost reel ; aucun certificat necessaire, dispo nginx >=1.19.4)
# Le prefixe '00-' le charge en premier ; le flag default_server est explicite
# donc l'ordre n'a de toute facon pas d'importance pour nginx.
cat > /etc/nginx/conf.d/00-default-server.conf <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOF

# Desactive tous les vhosts pre-existants (default Debian + autres) en vidant
# le repertoire sites-enabled. On garde le dir lui-meme : la nginx.conf default
# de Debian contient 'include /etc/nginx/sites-enabled/*;', et certaines
# versions de nginx failent 'nginx -t' si le path d'include n'existe pas du
# tout (vs path vide qui est tolere).
install -d /etc/nginx/sites-enabled
rm -f /etc/nginx/sites-enabled/*

nginx -t
systemctl enable --now nginx
systemctl reload nginx
