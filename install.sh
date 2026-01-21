#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/aliceout/vps-install.git"
DIR="vps-bootstrap"

if ! command -v git >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y git
fi

if [[ -d "$DIR" ]]; then
  echo "Le dossier $DIR existe deja. Supprime-le ou renomme-le."
  exit 1
fi

git clone "$REPO_URL" "$DIR"
cd "$DIR"

sudo bash ./bootstrap.sh