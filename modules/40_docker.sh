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

# Auth GHCR : si GHCR_TOKEN est present (Infisical /vps/_infra/), on logue
# DEUX users sur ghcr.io :
#   - $VPS_USER : pour les hooks webhook (qui tournent en VPS_USER via le
#     receiver) -> credential dans /home/$VPS_USER/.docker/config.json
#   - root : pour les `services install/update` manuels lances via sudo
#     -> credential dans /root/.docker/config.json
# Sans le login root, docker compose pull en root choue avec "unauthorized"
# sur les images privees.
if [[ -n "${GHCR_TOKEN:-}" ]]; then
  GHCR_LOGIN_USER="${GHCR_USER:-aliceout}"
  echo "Login GHCR pour root..."
  if printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_LOGIN_USER" --password-stdin >/dev/null; then
    echo "GHCR auth OK (root peut pull, requis pour 'sudo services install/update')."
  else
    echo "AVERTISSEMENT: docker login ghcr.io (root) echoue. Verifie GHCR_TOKEN."
  fi

  echo "Login GHCR pour $VPS_USER..."
  install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "/home/$VPS_USER/.docker"
  if printf '%s' "$GHCR_TOKEN" | runuser -u "$VPS_USER" -- \
       docker login ghcr.io -u "$GHCR_LOGIN_USER" --password-stdin >/dev/null; then
    echo "GHCR auth OK ($VPS_USER peut pull, requis pour les hooks webhook)."
  else
    echo "AVERTISSEMENT: docker login ghcr.io ($VPS_USER) echoue."
  fi
else
  echo "GHCR_TOKEN absent de /vps/_infra, skip docker login (les images publiques sont OK)."
fi

echo "Docker OK. (relogin pour que le groupe docker s'applique)"