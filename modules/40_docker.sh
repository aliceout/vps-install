#!/usr/bin/env bash
set -euo pipefail

# Fallback quand le module tourne standalone (sans bootstrap.sh qui exporte VPS_USER).
VPS_USER="${VPS_USER:-$(cat /etc/infisical/vps-user 2>/dev/null || true)}"

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

# Dimanche 04:00 - prune docker complet (system + buildx), wrappes Healthchecks
0 4 * * 0 root /usr/local/sbin/hc-run docker-prune /usr/bin/docker system prune -af --volumes --filter "until=168h" >> /var/log/docker-prune.log 2>&1
5 4 * * 0 root /usr/local/sbin/hc-run docker-buildx-prune /usr/bin/docker buildx prune -af --filter "until=168h" >> /var/log/docker-prune.log 2>&1
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

# Auth GHCR : si GHCR_TOKEN est present (Infisical /infra/<host>/ ou /infra/shared/), on logue
# DEUX users sur ghcr.io :
#   - $VPS_USER : pour les hooks webhook (qui tournent en VPS_USER via le
#     receiver) -> credential dans /home/$VPS_USER/.docker/config.json
#   - root : pour les `services install/update` manuels lances via sudo
#     -> credential dans /root/.docker/config.json
# Sans le login root, docker compose pull en root choue avec "unauthorized"
# sur les images privees.

# Template Infisical pour GHCR_TOKEN -> /etc/secrets/ghcr.env. Permet au module
# de retrouver la cle quand re-lance standalone (sans bootstrap qui exporte
# GHCR_TOKEN dans l'env). Token per-host : /infra/<host>/GHCR_TOKEN.
INFISICAL_PROJECT_ID="${INFISICAL_PROJECT_ID:-$(cat /etc/infisical/project-id 2>/dev/null || true)}"
INFISICAL_ENV="${INFISICAL_ENV:-$(cat /etc/infisical/environment 2>/dev/null || true)}"
HOST_TYPE="${HOST_TYPE:-$(cat /etc/infisical/host-type 2>/dev/null || true)}"
if [[ -n "$INFISICAL_PROJECT_ID" && -n "$INFISICAL_ENV" && -n "$HOST_TYPE" ]]; then
  install -d -m 755 /etc/infisical/templates
  install -d -m 700 /etc/infisical/agent.d
  install -d -m 700 /etc/secrets

  cat > /etc/infisical/templates/_ghcr.tmpl <<EOF
GHCR_TOKEN={{- with getSecretByName "${INFISICAL_PROJECT_ID}" "${INFISICAL_ENV}" "/infra/${HOST_TYPE}" "GHCR_TOKEN" }}{{ .Value }}{{- end }}
EOF

  cat > /etc/infisical/agent.d/_ghcr.yaml <<'EOF'
  - source-path: /etc/infisical/templates/_ghcr.tmpl
    destination-path: /etc/secrets/ghcr.env
    config:
      polling-interval: 300s
EOF
  chmod 600 /etc/infisical/agent.d/_ghcr.yaml

  if [[ -f /etc/infisical/agent.base.yaml ]]; then
    cp /etc/infisical/agent.base.yaml /etc/infisical/agent.yaml
    shopt -s nullglob
    for f in /etc/infisical/agent.d/*.yaml; do
      cat "$f" >> /etc/infisical/agent.yaml
    done
    shopt -u nullglob
    chmod 600 /etc/infisical/agent.yaml
    systemctl restart infisical-agent.service 2>/dev/null || true
  fi

  # Attente best-effort de la sync (~30s max). On checke que la cle a une
  # vraie valeur (pas juste 'GHCR_TOKEN=' renvoyé par l'agent si la cle est
  # absente cote Infisical), sinon le login plus bas skip silencieusement.
  for i in $(seq 1 30); do
    if [[ -s /etc/secrets/ghcr.env ]] && grep -qE '^GHCR_TOKEN=.+' /etc/secrets/ghcr.env; then
      break
    fi
    sleep 1
  done
  if [[ -s /etc/secrets/ghcr.env ]] && ! grep -qE '^GHCR_TOKEN=.+' /etc/secrets/ghcr.env; then
    echo "AVERTISSEMENT: /etc/secrets/ghcr.env genere mais GHCR_TOKEN vide. Cle absente de /infra/${HOST_TYPE}/ ?"
  fi
fi

# Charge GHCR_TOKEN depuis le fichier sync (fallback standalone).
if [[ -z "${GHCR_TOKEN:-}" && -s /etc/secrets/ghcr.env ]]; then
  # shellcheck disable=SC1091
  source /etc/secrets/ghcr.env
fi

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
  echo "GHCR_TOKEN absent de /infra/<host>/ et /infra/shared/, skip docker login (les images publiques sont OK)."
fi

echo "Docker OK. (relogin pour que le groupe docker s'applique)"