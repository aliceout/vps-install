#!/usr/bin/env bash
set -euo pipefail

echo "UFW + regles minimales (SSH $SSH_PORT, HTTP/HTTPS)"
apt-get install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

ufw allow "${SSH_PORT}/tcp"
if [[ "${WEB_ENABLED:-1}" -eq 1 ]]; then
  ufw allow 80/tcp
  ufw allow 443/tcp
fi

ufw --force enable

echo "Fail2ban"
apt-get install -y fail2ban nftables

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime = 1h
EOF

echo "Fail2ban: blocklists IP (badips)"
cat > /etc/fail2ban/filter.d/badips.conf <<'EOF'
[Definition]
failregex = ^$
EOF

cat > /etc/fail2ban/jail.d/badips.local <<'EOF'
[badips]
enabled = true
filter = badips
logpath = /var/log/fail2ban-list.log
maxretry = 1
findtime = 1d
bantime = -1
banaction = nftables-allports
EOF

touch /var/log/fail2ban-list.log

install -d /usr/local/sbin
cp -a "$ROOT_DIR/scripts/fail2ban-list.sh" /usr/local/sbin/fail2ban-list.sh
chmod +x /usr/local/sbin/fail2ban-list.sh

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

systemctl enable --now fail2ban