#!/usr/bin/env bash
set -euo pipefail

echo "Packages utilitaires"
apt-get install -y \
  git zsh vim-nox nano \
  ncdu btop htop fzf glances \
  bat lsd zoxide lolcat \
  jq unzip zip lnav \
  logrotate

echo "Depot azlux pour docker-ctop"
install -m 0755 -d /usr/share/keyrings
curl -fsSL https://azlux.fr/repo.gpg.key | gpg --dearmor -o /usr/share/keyrings/azlux-archive-keyring.gpg
ARCH="$(dpkg --print-architecture)"
CODENAME="$(lsb_release -cs)"
cat > /etc/apt/sources.list.d/azlux.list <<EOF
deb [arch=${ARCH} signed-by=/usr/share/keyrings/azlux-archive-keyring.gpg] http://packages.azlux.fr/debian ${CODENAME} main
EOF
apt-get update -y
apt-get install -y docker-ctop

echo "Installation lazydocker (script officiel)"
curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | bash

# bat = batcat sur Debian
command -v batcat >/dev/null 2>&1 || true
