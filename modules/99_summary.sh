#!/usr/bin/env bash
set -euo pipefail

say_header "Resume installation"

echo "- SSH: port $SSH_PORT, root desactive, passwords off"
echo "- UFW: allow $SSH_PORT/tcp + 80/443 (si web), deny all else"
echo "- Kernel hardening: /etc/sysctl.d/99-hardening.conf"
echo "- Audit: rkhunter (quotidien), debsecan (quotidien), lynis (hebdo) -> /var/log/audit/"
if command -v cscli >/dev/null 2>&1; then
  if cscli console status 2>/dev/null | grep -q "enrolled"; then
    echo "- CrowdSec: engine + bouncer nftables, enroll OK (voir https://app.crowdsec.net)"
  else
    echo "- CrowdSec: engine + bouncer nftables (standalone, sans enrollment)"
  fi
fi
if [[ "${DOCKER_ENABLED:-0}" -eq 1 ]]; then
  echo "- Docker: installe + user $VPS_USER dans groupe docker (relogin)"
fi
if [[ "${NODE_ENABLED:-0}" -eq 1 ]]; then
  echo "- Node.js + pm2: installes, pm2 au demarrage"
fi
if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
  echo "- Nginx: installe (vhosts crees par services/<nom>/nginx.conf)"
fi
echo "- ZRAM: swap en memoire (zram-tools)"
echo "- Cron: apt update/upgrade quotidiens"
echo "- Certbot DNS Infomaniak: renouvellement auto (certbot.timer)"
if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
  echo "- DNS Infomaniak: sync auto horaire (records A alignes sur IP publique)"
fi
echo "- CrowdSec hub refresh: hebdomadaire (dimanche 04:42)"
if [[ "${INFISICAL_ENABLED:-0}" -eq 1 ]]; then
  echo "- Infisical: CLI + agent (creds dans /etc/infisical/, secrets dans /etc/secrets/)"
fi

say_header "A FAIRE MAINTENANT"

say_warn "1. TESTER la connexion SSH depuis ton laptop, dans un NOUVEAU terminal"
say_warn "   (garde la session actuelle ouverte au cas ou) :"
echo
echo "     ssh -p ${SSH_PORT} ${VPS_USER}@<ip-du-vps>"
echo

say_warn "2. Si le login passe : rebooter pour appliquer le groupe docker a"
say_warn "   ${VPS_USER} et valider que tous les services remontent proprement :"
echo
echo "     sudo reboot"
echo

say_warn "3. Si le login echoue : debug depuis la session actuelle, NE PAS reboot,"
say_warn "   relance le bootstrap apres correction."

say_header "APRES REBOOT"

echo "- Re-ssh en ${VPS_USER} avec ta cle"
echo "- Verifie les services : systemctl --failed"
echo "- Installe un service : tape 'services' dans le zsh (alias vers service.sh)"
