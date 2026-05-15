#!/usr/bin/env bash
# Webhook hook pour 2mains. Appele par le webhooks receiver sur
# workflow_run "Docker build" success.
#
# Git-pull le repo puis exec scripts/deploy.sh (qui fetch les secrets
# app depuis Infisical Cloud (sous /services/<name>/), genere .env, docker compose pull/up).
#
# Source aussi /etc/secrets/2mains.env (cloud Infisical, sync par l'agent)
# avant deploy.sh, pour que les vars cloud (ADDRESS, PORT_*, DOMAIN, etc.)
# soient disponibles dans l'env du compose. Single source of truth = cloud.
set -Eeuo pipefail

DEPLOY_DIR="/var/www/2mains"
BRANCH="main"
CLOUD_ENV="/etc/secrets/2mains.env"
# Repo prive : SSH (cle deployee par 15_git_ssh.sh sous ~/.ssh/id_ed25519_github
# + config Host github.com).
REPO_URL="git@github.com:aliceout/2mains.git"

git config --global --add safe.directory "$DEPLOY_DIR" || true

if [[ -d "$DEPLOY_DIR/.git" ]]; then
  git -C "$DEPLOY_DIR" fetch --all --prune
  git -C "$DEPLOY_DIR" checkout "$BRANCH"
  git -C "$DEPLOY_DIR" reset --hard "origin/${BRANCH}"
else
  git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
fi

# Expose les vars cloud (ports, ADDRESS, etc.) a deploy.sh + au compose
if [[ -r "$CLOUD_ENV" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$CLOUD_ENV"
  set +a
fi

# cd dans le repo avant l'exec : sinon deploy.sh herite du CWD du parent
# (typiquement /opt/vps-install quand le hook tourne via 'services install')
# et ses 'git'/'docker compose' sans -C echouent.
cd "$DEPLOY_DIR"
exec bash scripts/deploy.sh "$@"
