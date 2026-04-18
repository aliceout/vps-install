#!/usr/bin/env bash
set -euo pipefail

# Recu en env: ACTION, SERVICE_NAME, SERVICE_DIR, SECRETS_FILE
# shellcheck disable=SC1091
source "$SERVICE_DIR/service.conf"

as_user() {
  sudo -u "$APP_USER" -H bash -c "$*"
}

ensure_dir() {
  if [[ ! -d "$APP_DIR" ]]; then
    install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
  fi
}

clone_or_pull() {
  ensure_dir
  if [[ -d "$APP_DIR/.git" ]]; then
    as_user "cd '$APP_DIR' && git fetch --all && git checkout '$REPO_BRANCH' && git pull --ff-only"
  else
    as_user "git clone --branch '$REPO_BRANCH' '$REPO_URL' '$APP_DIR'"
  fi
}

install_deps() {
  if [[ -f "$APP_DIR/package-lock.json" ]]; then
    as_user "cd '$APP_DIR' && npm ci --omit=dev"
  elif [[ -f "$APP_DIR/pnpm-lock.yaml" ]]; then
    as_user "cd '$APP_DIR' && pnpm install --prod --frozen-lockfile"
  elif [[ -f "$APP_DIR/yarn.lock" ]]; then
    as_user "cd '$APP_DIR' && yarn install --frozen-lockfile --production"
  else
    as_user "cd '$APP_DIR' && npm install --omit=dev"
  fi
}

# Lien vers le .env injecte par l'agent (propriete root, lecture via group ou sudo)
link_env() {
  if [[ -f "$SECRETS_FILE" ]]; then
    ln -sf "$SECRETS_FILE" "$APP_DIR/.env"
    chown -h "$APP_USER:$APP_USER" "$APP_DIR/.env" || true
  fi
}

pm2_start_or_reload() {
  if as_user "pm2 describe '$PM2_NAME' >/dev/null 2>&1"; then
    as_user "cd '$APP_DIR' && pm2 reload '$PM2_NAME' --update-env"
  else
    as_user "cd '$APP_DIR' && pm2 start '$PM2_SCRIPT' --name '$PM2_NAME'"
  fi
  as_user "pm2 save"
}

pm2_stop_delete() {
  as_user "pm2 delete '$PM2_NAME' || true"
  as_user "pm2 save || true"
}

case "$ACTION" in
  install|update)
    clone_or_pull
    install_deps
    link_env
    pm2_start_or_reload
    ;;
  remove)
    pm2_stop_delete
    ;;
  status)
    as_user "pm2 describe '$PM2_NAME' || echo 'non demarre'"
    ;;
  *)
    echo "Action inconnue: $ACTION"
    exit 1
    ;;
esac
