#!/usr/bin/env bash
# Deploy Work-resume via pm2.
# Toute la config vient de /etc/secrets/work.env (synce par l'agent
# Infisical depuis /services/work/) :
#   REPO    : ex "aliceout/Work-resume" (slug GitHub)
#   BRANCH  : ex "master"
#   APP     : nom pm2 (ex "work")
#   DIR     : chemin local (ex "/var/www/work")
#   PORT    : ex "4154"
#   GIT_URL : optionnel - URL clone explicite (default: git@github.com:$REPO.git)
set -euo pipefail

source /etc/secrets/work.env

: "${REPO:?REPO manquant dans /etc/secrets/work.env}"
: "${BRANCH:?BRANCH manquant}"
: "${APP:?APP manquant}"
: "${DIR:?DIR manquant}"
: "${PORT:?PORT manquant}"

GIT_URL="${GIT_URL:-git@github.com:${REPO}.git}"

mkdir -p "$(dirname "$DIR")"

if [[ ! -d "$DIR/.git" ]]; then
  echo "[$(date -Iseconds)] Premier run : clone $GIT_URL"
  git clone --branch "$BRANCH" "$GIT_URL" "$DIR"
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
