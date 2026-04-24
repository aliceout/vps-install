#!/usr/bin/env bash
# Webhook hook pour Nodea. Appele par le webhooks receiver sur
# workflow_run "Docker build" success.
# Git-pull le repo puis delegue a infra/scripts/deploy.sh (qui fetch
# l'Infisical self-hosted, genere le .env, docker compose pull + up + seed).
set -Eeuo pipefail

DEPLOY_DIR="/var/www/nodea"
BRANCH="main"
# Repo prive : on passe par SSH (cle deployee par 15_git_ssh.sh sous
# ~/.ssh/id_ed25519_github + config Host github.com).
REPO_URL="git@github.com:aliceout/Nodea.git"

git config --global --add safe.directory "$DEPLOY_DIR" || true

if [[ -d "$DEPLOY_DIR/.git" ]]; then
  git -C "$DEPLOY_DIR" fetch --all --prune
  git -C "$DEPLOY_DIR" checkout "$BRANCH"
  git -C "$DEPLOY_DIR" reset --hard "origin/${BRANCH}"
else
  git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
fi

exec bash "$DEPLOY_DIR/infra/scripts/deploy.sh" "$@"
