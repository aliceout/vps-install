#!/usr/bin/env bash
# Webhook hook pour tituba. Appele par le webhooks receiver sur
# workflow_run "Docker build" success.
#
# Git-pull le repo puis exec scripts/deploy.sh (qui fetch les secrets app
# depuis Infisical Cloud sous /services/tituba/<sous-dossier>, genere .env,
# docker compose pull && up -d).
#
# Source aussi /etc/secrets/tituba.env (cloud Infisical, sync par l'agent)
# avant deploy.sh, pour que les vars cloud (ADDRESS, PORT_*, DOMAIN, etc.)
# soient disponibles dans l'env du compose. Single source of truth = cloud.
set -Eeuo pipefail

DEPLOY_DIR="/var/www/tituba"
BRANCH="main"
CLOUD_ENV="/etc/secrets/tituba.env"
# Repo prive : SSH (cle deployee par 15_git_ssh.sh sous ~/.ssh/id_ed25519_github
# + config Host github.com). La cle doit avoir acces au repo aliceout/Tituba.
REPO_URL="git@github.com:aliceout/Tituba.git"

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
# (typiquement /opt/vps-install quand le hook tourne via 'services install').
cd "$DEPLOY_DIR"
exec bash scripts/deploy.sh "$@"
