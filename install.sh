#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/aliceout/vps-install.git"
DIR="vps-bootstrap"

if [[ $EUID -ne 0 ]]; then
  echo "Ce script doit tourner en root. Telecharge + review + lance via:" >&2
  echo "  curl -fsSLo install.sh https://raw.githubusercontent.com/aliceout/vps-install/main/install.sh" >&2
  echo "  less install.sh" >&2
  echo "  sudo bash install.sh" >&2
  exit 1
fi

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

echo "Verification BOM sur scripts..."
BAD=0
while IFS= read -r -d '' f; do
  head_hex="$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')"
  if [[ "$head_hex" == "efbbbf" ]]; then
    echo "BOM detecte: $f"
    BAD=1
  fi
done < <(find . -type f -name "*.sh" -print0)

if [[ "$BAD" -ne 0 ]]; then
  echo "Abandon: retire le BOM des scripts avant de lancer."
  exit 1
fi

bash ./bootstrap.sh
