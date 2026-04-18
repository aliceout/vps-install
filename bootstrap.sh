#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/vps-bootstrap.log"

export DOMAIN_MAIN=""
export PROXY_UPSTREAM=""
export NETDATA_DOMAIN=""
export NETDATA_UPSTREAM="http://127.0.0.1:19999"

exec > >(tee -a "$LOG") 2>&1

# --- Couleurs / helpers d'affichage (disponibles dans les modules via source) ---
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_CYAN=$'\033[36m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_RED=$'\033[31m'
C_MAGENTA=$'\033[35m'
C_BLUE=$'\033[34m'
export C_RESET C_BOLD C_DIM C_CYAN C_GREEN C_YELLOW C_RED C_MAGENTA C_BLUE

say_header() { printf '\n%s\n' "${C_BOLD}${C_MAGENTA}>> $*${C_RESET}"; }
say_module() { printf '\n%s\n' "${C_BOLD}${C_BLUE}---- MODULE: $* ----${C_RESET}"; }
say_info()   { printf '%s\n'  "${C_CYAN}$*${C_RESET}"; }
say_ok()     { printf '%s\n'  "${C_GREEN}$*${C_RESET}"; }
say_warn()   { printf '%s\n'  "${C_YELLOW}$*${C_RESET}"; }
say_err()    { printf '%s\n'  "${C_RED}$*${C_RESET}" >&2; }
export -f say_header say_module say_info say_ok say_warn say_err

say_header "vps-bootstrap: Debian 13"

if [[ $EUID -ne 0 ]]; then
  say_err "Lance-moi en root: sudo bash ./bootstrap.sh"
  exit 1
fi

read_tty() {
  local prompt="$1"
  local var_name="$2"
  local value=""
  local colored="${C_BOLD}${C_YELLOW}${prompt}${C_RESET}"
  if [[ -t 0 ]]; then
    read -r -p "$colored" value
  else
    read -r -p "$colored" value < /dev/tty
  fi
  printf -v "$var_name" '%s' "$value"
}

read_secret_tty() {
  local prompt="$1"
  local var_name="$2"
  local value=""
  local colored="${C_BOLD}${C_YELLOW}${prompt}${C_RESET}"
  if [[ -t 0 ]]; then
    read -r -s -p "$colored" value
  else
    read -r -s -p "$colored" value < /dev/tty
  fi
  echo
  printf -v "$var_name" '%s' "$value"
}

ask_yes_no() {
  local prompt="$1"
  local default="$2"
  local reply
  while true; do
    if [[ "$default" == "yes" ]]; then
      read_tty "$prompt [O/n]: " reply
    else
      read_tty "$prompt [o/N]: " reply
    fi
    reply="${reply,,}"
    if [[ -z "$reply" ]]; then
      [[ "$default" == "yes" ]] && return 0 || return 1
    fi
    case "$reply" in
      o|oui|y|yes) return 0 ;;
      n|non|no) return 1 ;;
      *) say_warn "Reponds par o/n." ;;
    esac
  done
}
export -f read_tty read_secret_tty ask_yes_no

# --- Preflight apt (ca-certificates, curl, etc.) avant d'installer le CLI ---
run_module() {
  local m="$1"
  say_module "$m"
  # shellcheck disable=SC1090
  source "$ROOT_DIR/modules/$m"
}

run_module "00_preflight.sh"

# --- Install du CLI Infisical ---
if ! command -v infisical >/dev/null 2>&1; then
  say_info "Install Infisical CLI..."
  curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | bash
  apt-get install -y infisical
fi

# --- Prompt credentials Infisical (ou reprise depuis /etc/infisical/ si deja persiste) ---
INFISICAL_CREDS_CACHED=0
if [[ -s /etc/infisical/client-id && -s /etc/infisical/client-secret \
   && -s /etc/infisical/project-id && -s /etc/infisical/environment ]]; then
  say_ok "Credentials Infisical deja persistes dans /etc/infisical/, reutilisation."
  INFISICAL_CLIENT_ID="$(cat /etc/infisical/client-id)"
  INFISICAL_CLIENT_SECRET="$(cat /etc/infisical/client-secret)"
  INFISICAL_PROJECT_ID="$(cat /etc/infisical/project-id)"
  INFISICAL_ENV="$(cat /etc/infisical/environment)"
  INFISICAL_ADDRESS="${INFISICAL_ADDRESS:-$(grep -E '^\s*address:' /etc/infisical/agent.base.yaml 2>/dev/null | awk '{print $2}')}"
  INFISICAL_ADDRESS="${INFISICAL_ADDRESS:-https://app.infisical.com}"
  INFISICAL_CREDS_CACHED=1
else
  INFISICAL_ADDRESS="${INFISICAL_ADDRESS:-https://app.infisical.com}"
  read_tty "Adresse Infisical [${INFISICAL_ADDRESS}]: " ADDR_INPUT
  if [[ -n "${ADDR_INPUT// }" ]]; then
    INFISICAL_ADDRESS="$ADDR_INPUT"
  fi

  INFISICAL_ENV="${INFISICAL_ENV:-prod}"
  read_tty "Environnement Infisical [${INFISICAL_ENV}]: " ENV_INPUT
  if [[ -n "${ENV_INPUT// }" ]]; then
    INFISICAL_ENV="$ENV_INPUT"
  fi

  INFISICAL_PROJECT_ID=""
  INFISICAL_CLIENT_ID=""
  INFISICAL_CLIENT_SECRET=""
  while [[ -z "${INFISICAL_PROJECT_ID// }" ]]; do
    read_tty "Infisical Project ID: " INFISICAL_PROJECT_ID
  done
  while [[ -z "${INFISICAL_CLIENT_ID// }" ]]; do
    read_tty "Infisical Machine Identity - Client ID: " INFISICAL_CLIENT_ID
  done
  while [[ -z "${INFISICAL_CLIENT_SECRET// }" ]]; do
    read_secret_tty "Infisical Machine Identity - Client Secret: " INFISICAL_CLIENT_SECRET
  done
fi

INFISICAL_PATH_INFRA="${INFISICAL_PATH_INFRA:-/vps/_infra}"

export INFISICAL_ADDRESS INFISICAL_ENV INFISICAL_PATH_INFRA INFISICAL_PROJECT_ID
export INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET

# --- Auth + fetch config depuis Infisical ---
say_info "Authentification Infisical..."
INFISICAL_ACCESS_TOKEN="$(
  infisical login \
    --method=universal-auth \
    --domain="$INFISICAL_ADDRESS" \
    --client-id="$INFISICAL_CLIENT_ID" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --plain --silent 2>/dev/null
)"
if [[ -z "$INFISICAL_ACCESS_TOKEN" ]]; then
  say_err "ERREUR: login Infisical echoue"
  exit 1
fi
export INFISICAL_TOKEN="$INFISICAL_ACCESS_TOKEN"

say_info "Recuperation config depuis ${INFISICAL_ADDRESS} (${INFISICAL_ENV}${INFISICAL_PATH_INFRA})..."
INFRA_ENV_CONTENT="$(
  infisical export \
    --domain="$INFISICAL_ADDRESS" \
    --token="$INFISICAL_TOKEN" \
    --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --path="$INFISICAL_PATH_INFRA" \
    --format=dotenv 2>/dev/null
)"
if [[ -z "$INFRA_ENV_CONTENT" ]]; then
  say_err "ERREUR: aucun secret recupere sous ${INFISICAL_PATH_INFRA}"
  exit 1
fi

# Charge les secrets dans l'env courant (export automatique)
set -a
# shellcheck disable=SC1090
source <(printf '%s\n' "$INFRA_ENV_CONTENT")
set +a

# Validation : variables obligatoires
REQUIRED=(VPS_USER VPS_USER_PASSWORD SSH_PORT SSH_PUBKEY LE_EMAIL)
missing=()
for v in "${REQUIRED[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done
if (( ${#missing[@]} > 0 )); then
  say_err "ERREUR: variables manquantes dans ${INFISICAL_PATH_INFRA}:"
  printf '  %s\n' "${C_RED}- ${missing[@]}${C_RESET}"
  exit 1
fi
say_ok "Config chargee depuis Infisical."

# --- Questions features (yes/no uniquement) ---
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
export INFISICAL_ENABLED=1

if [[ "$NETDATA_ENABLED" -eq 1 && "$WEB_ENABLED" -ne 1 ]]; then
  say_warn "Netdata desactive (besoin du reverse proxy web)."
  NETDATA_ENABLED=0
fi

export NETDATA_DOMAIN NETDATA_UPSTREAM

say_info "Config: user=${VPS_USER} | ssh_port=${SSH_PORT} | web=${WEB_ENABLED} | docker=${DOCKER_ENABLED} | node=${NODE_ENABLED} | netdata=${NETDATA_ENABLED}"

# --- Deroulement des modules ---
run_module "10_user_ssh.sh"
run_module "20_packages.sh"
run_module "25_zram.sh"
run_module "30_ufw_fail2ban.sh"
run_module "35_infisical.sh"

if [[ "$DOCKER_ENABLED" -eq 1 ]]; then
  run_module "40_docker.sh"
fi

if [[ "$NODE_ENABLED" -eq 1 ]]; then
  run_module "45_node_pm2.sh"
fi

if [[ "$WEB_ENABLED" -eq 1 ]]; then
  run_module "50_nginx.sh"
  run_module "75_certbot.sh"
fi

if [[ "$NETDATA_ENABLED" -eq 1 ]]; then
  say_info "Recuperation secrets Netdata depuis Infisical (/services/netdata)..."
  NETDATA_ENV_CONTENT="$(
    infisical export \
      --domain="$INFISICAL_ADDRESS" \
      --token="$INFISICAL_TOKEN" \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path=/services/netdata \
      --format=dotenv 2>/dev/null
  )"
  if [[ -n "$NETDATA_ENV_CONTENT" ]]; then
    set -a
    # shellcheck disable=SC1090
    source <(printf '%s\n' "$NETDATA_ENV_CONTENT")
    set +a
  else
    say_warn "Aucun secret sous /services/netdata (${INFISICAL_ENV}). Netdata sera installe mais pas expose."
  fi
  run_module "55_netdata.sh"
fi

run_module "60_zsh.sh"
run_module "70_cron_updates.sh"

run_module "99_summary.sh"

if ask_yes_no "Installer maintenant des services ?" "yes"; then
  bash "$ROOT_DIR/scripts/service.sh"
else
  say_info "Tu pourras lancer plus tard: sudo bash $ROOT_DIR/scripts/service.sh"
fi

say_ok "Bootstrap termine. Log: $LOG"
