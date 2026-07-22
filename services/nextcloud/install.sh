#!/usr/bin/env bash
# Reverse-proxy vhost pour Nextcloud AIO.
#
# L'application Nextcloud tourne dans la stack AIO (docker, geree hors de ce
# repo) et expose son apache sur 127.0.0.1:<PORT> (APACHE_PORT, defaut 11000).
# Ici on ne fait QUE le vhost nginx : il est rendu par scripts/service.sh
# (apply_nginx) a partir de nginx.conf. Rien a installer cote application.
#
# Cles attendues dans Infisical CLOUD sous /services/nextcloud/ :
#   - ADDRESS=cloud.alyss.cc
#   - DOMAIN=alyss.cc
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#   - PORT=11000            (APACHE_PORT de l'AIO)

set -euo pipefail

case "$ACTION" in
  install|update)
    echo "Vhost reverse-proxy Nextcloud AIO applique (rendu par apply_nginx)."
    echo "Prerequis : la stack AIO doit ecouter sur 127.0.0.1:<PORT> (APACHE_PORT)."
    echo "ATTENTION : retire tout ancien vhost manuel pour ce meme domaine, sinon"
    echo "            conflit de server_name avec /etc/nginx/conf/nextcloud.conf."
    ;;
  remove)
    echo "Vhost retire (voir remove_nginx). La stack AIO n'est pas touchee."
    ;;
  status)
    echo "=== nextcloud (reverse-proxy) ==="
    if command -v docker >/dev/null 2>&1; then
      docker ps --filter "name=nextcloud-aio" --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
    fi
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
