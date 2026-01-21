#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/vps-bootstrap.log"

export VPS_USER="choupi"
export SSH_PORT="45675"
export DOMAIN_MAIN=""
export PROXY_UPSTREAM=""
export NETDATA_DOMAIN=""
export NETDATA_UPSTREAM="http://127.0.0.1:19999"

exec > >(tee -a "$LOG") 2>&1

echo "== vps-bootstrap: Debian 13 =="

if [[ $EUID -ne 0 ]]; then
  echo "Lance-moi en root: sudo bash ./bootstrap.sh"
  exit 1
fi

ask_yes_no() {
  local prompt="$1"
  local default="$2"
  local reply
  while true; do
    if [[ "$default" == "yes" ]]; then
      read -r -p "$prompt [O/n]: " reply
    else
      read -r -p "$prompt [o/N]: " reply
    fi
    reply="${reply,,}"
    if [[ -z "$reply" ]]; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi
    case "$reply" in
      o|oui|y|yes) return 0 ;;
      n|non|no) return 1 ;;
      *) echo "Reponds par o/n." ;;
    esac
  done
}

read -r -p "Utilisateur a creer [choupi]: " VPS_USER_INPUT
if [[ -n "${VPS_USER_INPUT// }" ]]; then
  VPS_USER="$VPS_USER_INPUT"
fi

read -r -p "Port SSH [45675]: " SSH_PORT_INPUT
if [[ -n "${SSH_PORT_INPUT// }" ]]; then
  SSH_PORT="$SSH_PORT_INPUT"
fi

read -r -p "Colle ta cle SSH publique a autoriser (ex: ssh-ed25519 AAAA...): " SSH_PUBKEY
if [[ -z "${SSH_PUBKEY// }" ]]; then
  echo "Cle vide -> stop."
  exit 1
fi
export VPS_USER SSH_PORT SSH_PUBKEY

if ask_yes_no "Serveur web (nginx + reverse proxy) ?" "yes"; then
  WEB_ENABLED=1
else
  WEB_ENABLED=0
fi

if ask_yes_no "Installer Docker ?" "yes"; then
  DOCKER_ENABLED=1
else
  DOCKER_ENABLED=0
fi

if ask_yes_no "Installer Node.js + pm2 ?" "yes"; then
  NODE_ENABLED=1
else
  NODE_ENABLED=0
fi

if ask_yes_no "Installer Netdata (monitoring) ?" "yes"; then
  NETDATA_ENABLED=1
else
  NETDATA_ENABLED=0
fi

export WEB_ENABLED DOCKER_ENABLED NODE_ENABLED NETDATA_ENABLED

if [[ "$NETDATA_ENABLED" -eq 1 && "$WEB_ENABLED" -ne 1 ]]; then
  echo "Netdata desactive (besoin du reverse proxy web)."
  NETDATA_ENABLED=0
fi

export NETDATA_DOMAIN NETDATA_UPSTREAM

echo "Config: user=${VPS_USER} | ssh_port=${SSH_PORT} | web=${WEB_ENABLED} | docker=${DOCKER_ENABLED} | node=${NODE_ENABLED} | netdata=${NETDATA_ENABLED}"

echo "Note: domaines Certbot dans /etc/letsencrypt/domains.ini"
echo "Note: token Infomaniak dans /etc/letsencrypt/infomaniak.ini"

echo "Note: vhosts nginx a creer manuellement apres bootstrap."

echo "Note: exemple vhost (template) dans nginx/conf/template.conf"

run_module() {
  local m="$1"
  echo
  echo "---- MODULE: $m ----"
  # shellcheck disable=SC1090
  source "$ROOT_DIR/modules/$m"
}

run_module "00_preflight.sh"
run_module "10_user_ssh.sh"
run_module "20_packages.sh"
run_module "25_zram.sh"
run_module "30_ufw_fail2ban.sh"

if [[ "$DOCKER_ENABLED" -eq 1 ]]; then
  run_module "40_docker.sh"
fi

if [[ "$NODE_ENABLED" -eq 1 ]]; then
  run_module "45_node_pm2.sh"
fi

if [[ "$WEB_ENABLED" -eq 1 ]]; then
  run_module "50_nginx.sh"
fi

if [[ "$NETDATA_ENABLED" -eq 1 ]]; then
  run_module "55_netdata.sh"
fi

run_module "60_zsh.sh"
run_module "70_cron_updates.sh"

if [[ "$WEB_ENABLED" -eq 1 ]]; then
  run_module "75_certbot.sh"
fi

run_module "99_summary.sh"

echo
echo "OK. Log: $LOG"