#!/usr/bin/env bash
set -euo pipefail

echo "Cron: apt update + apt upgrade quotidiens (vrai upgrade)"
apt-get install -y cron
systemctl enable --now cron

install -d /usr/local/sbin
cat > /usr/local/sbin/apt-daily-update.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 9>/var/lock/apt-daily.lock
flock -n 9 || exit 0
export DEBIAN_FRONTEND=noninteractive
nice -n 10 ionice -c2 -n7 apt-get update -y
EOF

cat > /usr/local/sbin/apt-daily-upgrade.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec 9>/var/lock/apt-daily.lock
flock -n 9 || exit 0
export DEBIAN_FRONTEND=noninteractive
nice -n 10 ionice -c2 -n7 apt-get upgrade -y
nice -n 10 ionice -c2 -n7 apt-get autoremove -y
EOF

chmod +x /usr/local/sbin/apt-daily-update.sh /usr/local/sbin/apt-daily-upgrade.sh

rm -f /etc/cron.d/apt-daily /etc/cron.d/certbot-dns /etc/cron.d/fail2ban-badips

# (Tous les jours) 03:17 update, 03:27 upgrade
cat > /etc/cron.d/vps-bootstrap <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

17 3 * * * root /usr/local/sbin/apt-daily-update.sh >> /var/log/apt-daily.log 2>&1
27 3 * * * root /usr/local/sbin/apt-daily-upgrade.sh >> /var/log/apt-daily.log 2>&1

# Certbot DNS (si installe)
12 4 * * * root test -x /usr/local/sbin/certbot-dns && /usr/local/sbin/certbot-dns >> /var/log/cron/certbot-dns.log 2>&1

# Fail2ban bad IP lists
22 4 * * * root test -x /usr/local/sbin/fail2ban-list.sh && /usr/local/sbin/fail2ban-list.sh >> /var/log/cron/fail2ban-list.log 2>&1
EOF
