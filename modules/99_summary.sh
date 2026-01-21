#!/usr/bin/env bash
set -euo pipefail

echo "Resume:"
echo "- SSH: port $SSH_PORT, root desactive, passwords off"
echo "- UFW: allow $SSH_PORT/tcp + 80/443 (si web)"
if [[ "${DOCKER_ENABLED:-0}" -eq 1 ]]; then
  echo "- Docker: installe + user $VPS_USER dans groupe docker (relogin)"
fi
if [[ "${NODE_ENABLED:-0}" -eq 1 ]]; then
  echo "- Node.js + pm2: installes, pm2 au demarrage"
fi
if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
  if [[ -n "${DOMAIN_MAIN:-}" && -n "${PROXY_UPSTREAM:-}" ]]; then
    echo "- Nginx: vhost ${DOMAIN_MAIN} pret (reverse proxy -> ${PROXY_UPSTREAM})"
  else
    echo "- Nginx: installe (vhost a creer manuellement)"
  fi
fi
if [[ "${NETDATA_ENABLED:-0}" -eq 1 ]]; then
  if [[ -n "${NETDATA_DOMAIN:-}" ]]; then
    echo "- Netdata: reverse proxy ${NETDATA_DOMAIN} -> ${NETDATA_UPSTREAM}"
  else
    echo "- Netdata: installe (reverse proxy a configurer)"
    echo "  A faire: creer un vhost nginx avec nginx/conf/template.conf"
    echo "  Et pointer vers ${NETDATA_UPSTREAM}"
  fi
fi
echo "- ZRAM: swap en memoire (zram-tools)"
echo "- Cron: apt update/upgrade quotidiens"
echo "- Certbot DNS Infomaniak: domains.ini + infomaniak.ini"
echo "- Fail2ban: blocklists IP (maj quotidienne)"