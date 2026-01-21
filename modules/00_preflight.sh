#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

. /etc/os-release || true
if [[ "${ID:-}" != "debian" ]]; then
  echo "Ce script vise Debian. ID=$ID"
  exit 1
fi

echo "Mise à jour APT de base..."
apt-get update -y
apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https

echo "Timezone/locale (fr_FR.UTF-8)..."
apt-get install -y locales
sed -i 's/^# *fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8
