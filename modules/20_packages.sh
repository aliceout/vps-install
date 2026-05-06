#!/usr/bin/env bash
set -euo pipefail

echo "Packages utilitaires"
apt-get install -y \
  git zsh vim-nox nano \
  ncdu btop htop fzf glances \
  bat lsd zoxide lolcat \
  jq unzip zip lnav \
  bind9-dnsutils \
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
# DIR=/usr/local/bin : sinon le script installe dans $HOME/.local/bin/, qui
# en root devient /root/.local/bin/lazydocker (invisible pour le VPS_USER).
DIR=/usr/local/bin curl -fsSL https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh | DIR=/usr/local/bin bash

# pfetch : petit banner system info (pas dans les repos Debian)
if [[ ! -x /usr/local/bin/pfetch ]]; then
  curl -fsSL https://raw.githubusercontent.com/dylanaraps/pfetch/master/pfetch \
    -o /usr/local/bin/pfetch
  chmod 755 /usr/local/bin/pfetch
fi

# bat = batcat sur Debian
command -v batcat >/dev/null 2>&1 || true
