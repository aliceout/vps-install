#!/usr/bin/env bash
set -euo pipefail

echo "Docker (repo officiel Docker) + compose plugin"
# Doc Docker Debian 13: remove conflicts, add keyring, add repo, install packages. :contentReference[oaicite:5]{index=5}
apt-get remove -y docker.io docker-compose docker-doc podman-docker containerd runc || true

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

ARCH="$(dpkg --print-architecture)"
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable
EOF

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
usermod -aG docker "$VPS_USER"

echo "Docker OK. (relogin pour que le groupe docker s'applique)"