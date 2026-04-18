#!/usr/bin/env bash
set -euo pipefail

echo "Netdata (kickstart officiel)"

# Nettoie une eventuelle conf packagecloud qui pointe sur une suite non supportee
rm -f /etc/apt/sources.list.d/netdata_netdata.list
rm -f /etc/apt/sources.list.d/netdata_netdata-source.list

if ! command -v netdata >/dev/null 2>&1; then
  # Kickstart officiel : detecte la distro, choisit static/native, gere systemd
  # Flags : non-interactif, canal stable, sans telemetrie
  curl -fsSL https://get.netdata.cloud/kickstart.sh -o /tmp/netdata-kickstart.sh
  sh /tmp/netdata-kickstart.sh --non-interactive --stable-channel --disable-telemetry
  rm -f /tmp/netdata-kickstart.sh
fi

# Ecoute en local uniquement (le reverse proxy nginx se charge de l'expo HTTPS)
install -d /etc/netdata
cat > /etc/netdata/netdata.conf <<'EOF'
[web]
bind to = 127.0.0.1
EOF

# Desactive la telemetrie anonyme au cas ou le flag aurait rate
touch /etc/netdata/.opt-out-from-anonymous-statistics

systemctl enable --now netdata
systemctl restart netdata
