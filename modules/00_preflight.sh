#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

. /etc/os-release || true
if [[ "${ID:-}" != "debian" ]]; then
  echo "Ce script vise Debian. ID=$ID"
  exit 1
fi

# Repare les keyrings apt laisses en 0600 par des runs anterieurs (sqv les exige world-readable)
for d in /usr/share/keyrings /etc/apt/keyrings; do
  if [[ -d "$d" ]]; then
    find "$d" -maxdepth 1 -type f \( -name '*.gpg' -o -name '*.asc' \) -exec chmod a+r {} \; 2>/dev/null || true
  fi
done

# Supprime les sources list connues pour etre cassees suite a des tentatives anterieures
# (packagecloud netdata pas de suite trixie, etc.) pour ne pas bloquer apt-get update
rm -f /etc/apt/sources.list.d/netdata_netdata.list \
      /etc/apt/sources.list.d/netdata_netdata-source.list

echo "Mise à jour APT de base..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

echo "Timezone/locale (fr_FR.UTF-8)..."
apt-get install -y locales
sed -i 's/^# *fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8
