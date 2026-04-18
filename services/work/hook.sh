#!/usr/bin/env bash
# Deploy Work-resume (Next.js) via pm2.
# Idempotent : clone si absent, sinon pull. Lance par webhooks a chaque push.
set -euo pipefail

REPO="git@github.com:aliceout/Work-resume.git"
DIR="/var/www/work"
BRANCH="master"
APP="work"
PORT="4154"

mkdir -p "$(dirname "$DIR")"

if [[ ! -d "$DIR/.git" ]]; then
  echo "[$(date -Iseconds)] Premier run : clone $REPO"
  git clone --branch "$BRANCH" "$REPO" "$DIR"
fi

cd "$DIR"

git fetch origin "$BRANCH"
git checkout "$BRANCH"
git reset --hard "origin/$BRANCH"

rm -f yarn.lock

if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

npm run build

if pm2 describe "$APP" >/dev/null 2>&1; then
  pm2 restart "$APP" --update-env
else
  PORT="$PORT" NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 \
    pm2 start npm --name "$APP" -- start
fi

pm2 save >/dev/null 2>&1 || true

echo "[$(date -Iseconds)] $APP deploye"
