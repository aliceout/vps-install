#!/usr/bin/env bash
set -euo pipefail

echo "UFW + regles minimales (SSH $SSH_PORT, HTTP/HTTPS)"
apt-get install -y ufw nftables

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
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

echo "CrowdSec (repo + engine + bouncer nftables)"

if ! command -v cscli >/dev/null 2>&1; then
  curl -fsSL https://install.crowdsec.net | sh
fi
apt-get install -y crowdsec crowdsec-firewall-bouncer-nftables

echo "CrowdSec collections"
# Base Linux + SSH (toujours)
cscli collections install crowdsecurity/linux --force
cscli collections install crowdsecurity/sshd --force
cscli collections install crowdsecurity/linux-lpe --force 2>/dev/null || true

# Web (scenarios HTTP + CVE) si nginx present
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
  echo "Pas de CROWDSEC_ENROLL_KEY dans /vps/_infra, CrowdSec tourne en standalone."
  echo "Pour enroller plus tard: cscli console enroll <cle> (cle dispo sur https://app.crowdsec.net)"
fi

systemctl enable --now crowdsec
systemctl restart crowdsec
systemctl enable --now crowdsec-firewall-bouncer
systemctl restart crowdsec-firewall-bouncer
