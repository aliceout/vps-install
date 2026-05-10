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

# Log rotation par defaut au niveau daemon. Sans ca, json-file grossit
# indefiniment (un container bavard peut bouffer 10 GB en quelques semaines).
# Affecte UNIQUEMENT les containers crees apres ce restart de docker.
# 10 MB max par fichier, 3 fichiers = 30 MB max par container.
install -d -m 755 /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
chmod 644 /etc/docker/daemon.json

systemctl enable --now docker
systemctl restart docker
usermod -aG docker "$VPS_USER"

# Cron weekly : prune des images / containers / build cache non utilises.
# system prune --volumes ne touche PAS les volumes nommes (uniquement les
# anonymes). Filter "until=168h" garde les images recentes meme si
# temporairement non utilisees (evite de re-pull immediatement apres push).
cat > /etc/cron.d/vps-docker-prune <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Dimanche 04:00 - prune docker complet (system + buildx)
0 4 * * 0 root /usr/bin/docker system prune -af --volumes --filter "until=168h" >> /var/log/docker-prune.log 2>&1
5 4 * * 0 root /usr/bin/docker buildx prune -af --filter "until=168h" >> /var/log/docker-prune.log 2>&1
EOF
chmod 644 /etc/cron.d/vps-docker-prune

# Logrotate pour le log du prune lui-meme
cat > /etc/logrotate.d/vps-docker-prune <<'EOF'
/var/log/docker-prune.log {
    monthly
    rotate 6
    missingok
    notifempty
    compress
    delaycompress
}
EOF

# Auth GHCR : si GHCR_TOKEN est present (Infisical /infra/vps/), on logue
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
  echo "GHCR_TOKEN absent de /infra/vps, skip docker login (les images publiques sont OK)."
fi

echo "Docker OK. (relogin pour que le groupe docker s'applique)"