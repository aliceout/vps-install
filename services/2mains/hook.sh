#!/usr/bin/env bash
# Webhook hook pour 2mains. Appele par le webhooks receiver sur
# workflow_run "Docker build" success.
#
# Git-pull le repo puis exec infra/scripts/deploy.sh (qui fetch les
# secrets app depuis Infisical self-hosted, genere .env, docker compose
# pull/up).
set -Eeuo pipefail

DEPLOY_DIR="/var/www/2mains"
BRANCH="main"
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

exec bash "$DEPLOY_DIR/infra/scripts/deploy.sh" "$@"
