#!/usr/bin/env bash
# Webhook hook pour Korai. Appele par le webhooks receiver sur push GitHub.
# Git-pull le repo puis delegue a infra/scripts/deploy.sh (qui fetch Infisical,
# pull les images GHCR, docker compose down -v + up -d, seed).
set -Eeuo pipefail

DEPLOY_DIR="/var/www/korai"
BRANCH="main"
# Repo prive : on passe par SSH (cle deployee par 15_github_ssh.sh sous
# ~/.ssh/id_ed25519 + config Host github.com). Pas de HTTPS qui demanderait
# un PAT.
REPO_URL="git@github.com:aliceout/Korai.git"

git config --global --add safe.directory "$DEPLOY_DIR" || true

if [[ -d "$DEPLOY_DIR/.git" ]]; then
  git -C "$DEPLOY_DIR" fetch --all --prune
  git -C "$DEPLOY_DIR" checkout "$BRANCH"
  git -C "$DEPLOY_DIR" reset --hard "origin/${BRANCH}"
else
  git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_DIR"
fi

exec bash "$DEPLOY_DIR/infra/scripts/deploy.sh" "$@"
