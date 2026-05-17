#!/usr/bin/env bash
set -euo pipefail

# Fallback standalone : SSH_PORT vient normalement de bootstrap.sh, mais quand
# on relance ce module a la main (post-bootstrap, pour fix UFW), il n'est pas
# en env. On le lit alors depuis sshd -T (config effective, prend en compte
# tous les drop-ins). Last resort: 22.
if [[ -z "${SSH_PORT:-}" ]]; then
  SSH_PORT="$(sshd -T 2>/dev/null | awk 'tolower($1) == "port" { print $2; exit }')"
  SSH_PORT="${SSH_PORT:-22}"
fi
# WEB_FIREWALL_ENABLED + DOCKER_ENABLED ont deja leur defaults dans les
# expressions ${VAR:-X} plus bas, pas besoin d'init explicite.

echo "UFW + regles minimales (SSH $SSH_PORT, HTTP/HTTPS)"
apt-get install -y ufw nftables

# Idempotent : on ne reset PAS si UFW tourne deja. 'ufw --force reset' vide
# toutes les regles avant de re-appliquer -> fenetre d'exposition pendant le
# re-bootstrap d'un host vivant. Les commandes 'ufw default' et 'ufw allow'
# sont elles-memes idempotentes, donc inutile de reset systematiquement.
# Pour reset volontairement, lance manuellement 'sudo ufw reset' avant.
if ! ufw status 2>/dev/null | grep -q 'Status: active'; then
  ufw --force reset
fi
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
# WEB_FIREWALL_ENABLED gate l'ouverture des ports HTTP/HTTPS independamment
# de WEB_ENABLED (qui pilote l'install de nginx). Permet d'avoir un nginx
# pre-existant accessible sans laisser le framework le reinstaller. Fallback
# sur WEB_ENABLED pour la compat avec les bootstraps deja faits.
if [[ "${WEB_FIREWALL_ENABLED:-${WEB_ENABLED:-1}}" -eq 1 ]]; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

ufw --force enable

if [[ "${DOCKER_ENABLED:-0}" -eq 1 ]]; then
  echo "UFW + Docker (pas de bypass)"
  sed -i -E 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="DROP"/' /etc/default/ufw

  if ! grep -q "DOCKER-USER" /etc/ufw/after.rules; then
    awk '
      BEGIN{added=0}
      /^\*filter/ {print; next}
      /^COMMIT/ && !added {
        print ":DOCKER-USER - [0:0]"
        print "-A DOCKER-USER -j ufw-user-forward"
        print "-A DOCKER-USER -j RETURN"
        added=1
      }
      {print}
    ' /etc/ufw/after.rules > /etc/ufw/after.rules.tmp && mv /etc/ufw/after.rules.tmp /etc/ufw/after.rules
  fi

  if [[ -f /etc/ufw/after6.rules ]] && ! grep -q "DOCKER-USER" /etc/ufw/after6.rules; then
    awk '
      BEGIN{added=0}
      /^\*filter/ {print; next}
      /^COMMIT/ && !added {
        print ":DOCKER-USER - [0:0]"
        print "-A DOCKER-USER -j ufw-user-forward"
        print "-A DOCKER-USER -j RETURN"
        added=1
      }
      {print}
    ' /etc/ufw/after6.rules > /etc/ufw/after6.rules.tmp && mv /etc/ufw/after6.rules.tmp /etc/ufw/after6.rules
  fi
fi

systemctl reload ufw || true

# --- CrowdSec : detection + bouncer nftables ----------------------------------

echo "CrowdSec (repo + engine)"

if ! command -v cscli >/dev/null 2>&1; then
  curl -fsSL https://install.crowdsec.net | sh
fi
apt-get install -y crowdsec

# Demarre le LAPI avant tout pour que le postinst du bouncer et les enrollments
# puissent s'y connecter.
systemctl enable --now crowdsec
for i in $(seq 1 30); do
  cscli lapi status >/dev/null 2>&1 && break
  sleep 1
done

echo "CrowdSec collections"
cscli collections install crowdsecurity/linux --force
cscli collections install crowdsecurity/sshd --force
cscli collections install crowdsecurity/linux-lpe --force 2>/dev/null || true

if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
  cscli collections install crowdsecurity/nginx --force
  cscli collections install crowdsecurity/base-http-scenarios --force
  cscli collections install crowdsecurity/http-cve --force
fi

# Enrollment sur app.crowdsec.net si cle fournie
if [[ -n "${CROWDSEC_ENROLL_KEY:-}" ]]; then
  echo "CrowdSec: enrollment console"
  cscli console enroll -e context "${CROWDSEC_ENROLL_KEY}" --name "$(hostname -s)" 2>&1 || {
    echo "AVERTISSEMENT: enrollment echoue (cle invalide ou deja utilisee). Tu peux le faire a la main: cscli console enroll <cle>"
  }
else
  echo "Pas de CROWDSEC_ENROLL_KEY dans /infra/vps, CrowdSec tourne en standalone."
  echo "Pour enroller plus tard: cscli console enroll <cle> (cle dispo sur https://app.crowdsec.net)"
fi

systemctl reload crowdsec

echo "CrowdSec bouncer (nftables)"
apt-get install -y crowdsec-firewall-bouncer-nftables

# Safety net: si le postinst n'a pas ecrit l'API key (race avec le LAPI qui
# demarrait), on la regenere nous-memes.
BOUNCER_CONF="/etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml"
BOUNCER_NAME="cs-firewall-bouncer"
if [[ -f "$BOUNCER_CONF" ]] && ! grep -qE '^api_key:\s+[A-Za-z0-9]' "$BOUNCER_CONF"; then
  echo "Registration manuelle du bouncer..."
  cscli bouncers delete "$BOUNCER_NAME" 2>/dev/null || true
  API_KEY="$(cscli bouncers add "$BOUNCER_NAME" -o raw)"
  sed -i "s|^api_key:.*|api_key: ${API_KEY}|" "$BOUNCER_CONF"
fi

systemctl enable --now crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer

if ! systemctl is-active --quiet crowdsec-firewall-bouncer; then
  echo "ERREUR: crowdsec-firewall-bouncer.service n'a pas demarre. Diagnostic:"
  systemctl status crowdsec-firewall-bouncer.service --no-pager || true
  journalctl -xeu crowdsec-firewall-bouncer.service --no-pager -n 50 || true
fi
