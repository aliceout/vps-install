#!/usr/bin/env bash
# Reverse-proxy vhost pour l'interface master de Nextcloud AIO.
#
# La stack AIO (docker, geree hors de ce repo) expose son interface d'admin
# (mastercontainer, port 8080 du conteneur) sur l'hote via le mapping
# "<PORT>:8080" de son docker-compose. Ici on ne fait QUE le vhost nginx,
# rendu par scripts/service.sh (apply_nginx) depuis nginx.conf : cert,
# record DNS et vhost sont geres par le framework. Rien n'est touche cote AIO.
#
# A ne pas confondre avec le service "nextcloud", qui proxifie Nextcloud
# lui-meme (APACHE_PORT, 11000). Le domaine Nextcloud stocke par l'AIO
# (configuration.json) est independant de l'adresse de cette interface.
#
# Cles attendues dans Infisical CLOUD sous /services/nextcloud-aio/ :
#   - ADDRESS=cloud.backlice.cc
#   - DOMAIN=backlice.cc
#   - PORT=8087              (port hote mappe sur le 8080 du mastercontainer)
#   - DNS_PROVIDER, DNS_TOKEN_NAME

set -euo pipefail

case "$ACTION" in
  install|update)
    echo "Vhost reverse-proxy de l'interface master AIO applique (rendu par apply_nginx)."
    echo "Prerequis : le mastercontainer doit ecouter sur 127.0.0.1:<PORT> (mapping <PORT>:8080)."
    echo "Si un ancien vhost manuel servait l'interface AIO (ex: cloud-back.conf"
    echo "pour cloud.backlice.eu), retire-le une fois celui-ci valide."
    ;;
  remove)
    echo "Vhost retire (voir remove_nginx). La stack AIO n'est pas touchee."
    ;;
  status)
    echo "=== nextcloud-aio (reverse-proxy interface master) ==="
    if command -v docker >/dev/null 2>&1; then
      docker ps --filter "name=nextcloud-aio-mastercontainer" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null || true
    fi
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
