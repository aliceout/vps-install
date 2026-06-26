#!/usr/bin/env bash
# Install alyss.cc - holding page racine (statique, servie par nginx).
#
# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE
#
# Cles attendues dans Infisical CLOUD sous /services/alyss-root/ :
#   - ADDRESS=alyss.cc
#   - DOMAIN=alyss.cc
#   - DNS_PROVIDER, DNS_TOKEN_NAME
#
# Aucun secret applicatif : c'est une page statique anonyme. Le vhost est rendu
# par scripts/service.sh (apply_nginx) ; ici on ne fait que deposer le HTML.

set -euo pipefail

WEBROOT="/var/www/${SERVICE_NAME}"

case "$ACTION" in
  install|update)
    install -d -m 755 "$WEBROOT"
    install -m 644 "$SERVICE_DIR/index.html" "$WEBROOT/index.html"
    echo "Holding page deployee: $WEBROOT/index.html"
    ;;

  remove)
    rm -rf "$WEBROOT"
    echo "Holding page retiree: $WEBROOT"
    ;;

  status)
    if [[ -f "$WEBROOT/index.html" ]]; then
      echo "OK : $WEBROOT/index.html ($(stat -c '%s octets, modifie %y' "$WEBROOT/index.html"))"
    else
      echo "Absent : $WEBROOT/index.html"
    fi
    ;;

  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
