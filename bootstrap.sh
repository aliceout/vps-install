#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="/var/log/vps-bootstrap.log"

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
  local mname="${m%.sh}"
  if [[ -n "${SKIP_MODULES:-}" ]]; then
    local IFS=','
    for s in $SKIP_MODULES; do
      s="${s// /}"
      [[ -z "$s" ]] && continue
      if [[ "$mname" == "$s" || "$m" == "$s" ]]; then
        say_warn "Skip module $m (SKIP_MODULES)"
        return 0
      fi
    done
  fi
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

INFISICAL_PATH_SHARED="/infra/shared"

# --- Auth Infisical (en avance, pour pouvoir lister les sous-dossiers /infra/) ---
export INFISICAL_ADDRESS INFISICAL_ENV INFISICAL_PROJECT_ID
export INFISICAL_CLIENT_ID INFISICAL_CLIENT_SECRET

say_info "Authentification Infisical..."
INFISICAL_AUTH_ERR="$(mktemp)"
INFISICAL_ACCESS_TOKEN="$(
  infisical login \
    --method=universal-auth \
    --domain="$INFISICAL_ADDRESS" \
    --client-id="$INFISICAL_CLIENT_ID" \
    --client-secret="$INFISICAL_CLIENT_SECRET" \
    --plain </dev/null 2>"$INFISICAL_AUTH_ERR" || true
)"
if [[ -z "$INFISICAL_ACCESS_TOKEN" ]]; then
  say_err "ERREUR: login Infisical echoue. Sortie du CLI :"
  cat "$INFISICAL_AUTH_ERR" >&2
  rm -f "$INFISICAL_AUTH_ERR"
  exit 1
fi
rm -f "$INFISICAL_AUTH_ERR"
export INFISICAL_TOKEN="$INFISICAL_ACCESS_TOKEN"

# Helper : liste les sous-dossiers de /infra/, exclut 'shared'.
list_infra_hosts() {
  infisical secrets folders get \
    --domain="$INFISICAL_ADDRESS" \
    --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --path="/infra" \
    --token="$INFISICAL_TOKEN" 2>/dev/null \
    | awk '
        /^│/ && !/FOLDER NAME/ {
          n = split($0, parts, "│")
          if (n >= 2) {
            name = parts[2]
            gsub(/^[ \t]+|[ \t]+$/, "", name)
            if (name != "" && name != "shared") print name
          }
        }' \
    | sort -u
}

# --- Host type detection ---
# 1er run : liste les sous-dossiers /infra/* (hors shared) et prompte.
# Persiste dans /etc/infisical/host-type. Override via env HOST_TYPE.
# Re-runs : lit le fichier persiste.
HOST_TYPE_FILE="/etc/infisical/host-type"
if [[ -n "${HOST_TYPE:-}" ]]; then
  say_info "Host type force par env: $HOST_TYPE"
elif [[ -s "$HOST_TYPE_FILE" ]]; then
  HOST_TYPE="$(cat "$HOST_TYPE_FILE")"
  say_ok "Host type lu depuis $HOST_TYPE_FILE: $HOST_TYPE"
else
  AVAILABLE_HOSTS="$(list_infra_hosts)"
  if [[ -n "$AVAILABLE_HOSTS" ]]; then
    say_info "Hosts existants dans /infra/ (hors 'shared'):"
    while IFS= read -r h; do
      [[ -n "$h" ]] && printf '  - %s\n' "$h"
    done <<< "$AVAILABLE_HOSTS"
  else
    say_warn "Aucun sous-dossier dans /infra/ (a part 'shared'). Tu vas en creer un."
  fi
  HOST_TYPE=""
  while [[ -z "$HOST_TYPE" ]]; do
    read_tty "Type d'host: " HOST_TYPE
    HOST_TYPE="$(printf '%s' "$HOST_TYPE" | tr -d ' \t\n\r')"
    if [[ "$HOST_TYPE" == "shared" ]]; then
      say_warn "'shared' est reserve aux cles communes, choisis un autre nom."
      HOST_TYPE=""
    fi
  done
fi
if [[ -z "$HOST_TYPE" || "$HOST_TYPE" == "shared" ]]; then
  say_err "HOST_TYPE invalide: '$HOST_TYPE' (vide ou 'shared' reserve)"
  exit 1
fi
install -d -m 755 /etc/infisical
printf '%s' "$HOST_TYPE" > "$HOST_TYPE_FILE"
chmod 644 "$HOST_TYPE_FILE"
export HOST_TYPE

INFISICAL_PATH_INFRA="${INFISICAL_PATH_INFRA:-/infra/$HOST_TYPE}"

# --- Install mode (fresh | existing) ---
# fresh    : lance tous les modules (defaut sur un host neuf)
# existing : skip 10_user_ssh.sh (utile sur un host deja configure - evite
#            de toucher au user existant, port SSH, authorized_keys, et de
#            couper la session SSH en cours).
INSTALL_MODE_FILE="/etc/infisical/install-mode"
if [[ -n "${INSTALL_MODE:-}" ]]; then
  say_info "Install mode force par env: $INSTALL_MODE"
elif [[ -s "$INSTALL_MODE_FILE" ]]; then
  INSTALL_MODE="$(cat "$INSTALL_MODE_FILE")"
  say_ok "Install mode lu depuis $INSTALL_MODE_FILE: $INSTALL_MODE"
else
  if ask_yes_no "Le user et SSH sont-ils deja configures sur cette machine ?" "no"; then
    INSTALL_MODE="existing"
  else
    INSTALL_MODE="fresh"
  fi
fi
case "$INSTALL_MODE" in
  fresh|existing) ;;
  *) say_err "INSTALL_MODE invalide: '$INSTALL_MODE' (attendu: fresh|existing)"; exit 1 ;;
esac
printf '%s' "$INSTALL_MODE" > "$INSTALL_MODE_FILE"
chmod 644 "$INSTALL_MODE_FILE"
export INSTALL_MODE

if [[ "$INSTALL_MODE" == "existing" ]]; then
  SKIP_MODULES="${SKIP_MODULES:+${SKIP_MODULES},}10_user_ssh"
  say_warn "Mode existing : skip 10_user_ssh.sh."
fi
export SKIP_MODULES="${SKIP_MODULES:-}"

# INFISICAL_PATH_INFRA reste local au bootstrap (les modules utilisent /etc/infisical/*
# pour leurs propres lookups).

say_info "Recuperation config depuis ${INFISICAL_ADDRESS} (${INFISICAL_ENV}: ${INFISICAL_PATH_SHARED} + ${INFISICAL_PATH_INFRA})..."

# `infisical export --format=dotenv` encode les newlines en '\n' litteral,
# que bash source ne decode pas. On fetch chaque cle individuellement avec
# --plain pour preserver les valeurs multiligne (SSH keys, certs, etc.).
fetch_secret() {
  local k="$1" path="$2"
  infisical secrets get "$k" \
    --domain="$INFISICAL_ADDRESS" \
    --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENV" \
    --path="$path" \
    --token="$INFISICAL_TOKEN" \
    --plain 2>/dev/null || true
}

INFRA_KEYS=(
  VPS_USER VPS_USER_PASSWORD
  SSH_PORT SSH_PUBKEY
  CROWDSEC_ENROLL_KEY GITHUB_SSH_PRIVKEY GITLAB_SSH_PRIVKEY
  GHCR_TOKEN GHCR_USER
)
# CERTBOT_EMAIL + INFOMANIAK_TOKEN ont ete deplaces vers /certbot/ (lu
# par 75_certbot.sh / certbot-refresh-creds). Ici on ne les exige plus.

got_any=0
for k in "${INFRA_KEYS[@]}"; do
  # Fetch shared d'abord (priorite basse), puis host-specific (override
  # si la cle existe aussi dans /infra/<host>/).
  for path in "$INFISICAL_PATH_SHARED" "$INFISICAL_PATH_INFRA"; do
    v="$(fetch_secret "$k" "$path")"
    if [[ -n "$v" ]]; then
      export "$k=$v"
      got_any=1
    fi
  done
done

if [[ "$got_any" -eq 0 ]]; then
  say_err "ERREUR: aucun secret recupere sous ${INFISICAL_PATH_SHARED} ni ${INFISICAL_PATH_INFRA}"
  exit 1
fi

# Validation : variables obligatoires.
# En mode 'existing', VPS_USER_PASSWORD et SSH_PUBKEY ne sont pas requis
# (10_user_ssh.sh est skip), mais VPS_USER doit exister sur le systeme.
if [[ "$INSTALL_MODE" == "existing" ]]; then
  REQUIRED=(VPS_USER SSH_PORT)
else
  REQUIRED=(VPS_USER VPS_USER_PASSWORD SSH_PORT SSH_PUBKEY)
fi
missing=()
for v in "${REQUIRED[@]}"; do
  if [[ -z "${!v:-}" ]]; then
    missing+=("$v")
  fi
done
if (( ${#missing[@]} > 0 )); then
  say_err "ERREUR: variables manquantes dans ${INFISICAL_PATH_SHARED} ou ${INFISICAL_PATH_INFRA}:"
  # printf repete le format pour chaque arg : chaque cle manquante a ses
  # propres codes couleur (avant on prefixait C_RED a la 1ere uniquement et
  # suffixait C_RESET a la derniere, donc toutes les lignes du milieu
  # heritaient du rouge sans reset).
  printf "  ${C_RED}- %s${C_RESET}\n" "${missing[@]}"
  exit 1
fi
if [[ "$INSTALL_MODE" == "existing" ]] && ! id -u "$VPS_USER" >/dev/null 2>&1; then
  say_err "ERREUR: INSTALL_MODE=existing mais le user '$VPS_USER' n'existe pas sur ce systeme."
  say_err "Cree-le manuellement, ou passe en mode fresh."
  exit 1
fi
say_ok "Config chargee depuis Infisical."

# --- Questions features (yes/no uniquement) ---
if ask_yes_no "Installer nginx + reverse proxy + certbot + collections CrowdSec nginx ?" "yes"; then
  WEB_ENABLED=1
else
  WEB_ENABLED=0
fi

# Decouple l'ouverture firewall 80/443 de l'install nginx : si tu reponds non
# a la question precedente parce que tu as deja ton propre nginx, tu peux
# quand meme demander a ce que les ports HTTP/HTTPS soient ouverts dans ufw.
if [[ "$WEB_ENABLED" -eq 1 ]]; then
  WEB_FIREWALL_ENABLED=1
else
  if ask_yes_no "Ouvrir quand meme HTTP/HTTPS (80/443) dans le firewall (nginx deja existant) ?" "no"; then
    WEB_FIREWALL_ENABLED=1
  else
    WEB_FIREWALL_ENABLED=0
  fi
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

export WEB_ENABLED WEB_FIREWALL_ENABLED DOCKER_ENABLED NODE_ENABLED
export INFISICAL_ENABLED=1

say_info "Config: user=${VPS_USER} | ssh_port=${SSH_PORT} | web=${WEB_ENABLED} | docker=${DOCKER_ENABLED} | node=${NODE_ENABLED}"

# --- Deroulement des modules ---
run_module "10_user_ssh.sh"
run_module "15_git_ssh.sh"
run_module "20_packages.sh"
run_module "25_zram.sh"
run_module "27_log_retention.sh"
run_module "28_sysctl.sh"
run_module "29_audit_tools.sh"
run_module "30_ufw_crowdsec.sh"
run_module "35_infisical.sh"

if [[ "$DOCKER_ENABLED" -eq 1 ]]; then
  run_module "40_docker.sh"
fi

# Scripts server-only : le module skip lui-meme si HOST_TYPE != server.
run_module "41_server_scripts.sh"

if [[ "$NODE_ENABLED" -eq 1 ]]; then
  run_module "45_node_pm2.sh"
fi

if [[ "$WEB_ENABLED" -eq 1 ]]; then
  run_module "50_nginx.sh"
  run_module "75_certbot.sh"
fi

run_module "60_zsh.sh"
run_module "70_cron_updates.sh"

# Persiste le repo dans un chemin stable (/opt/vps-install) pour les re-runs
# et l'alias `services` dans le zshrc.
if [[ "$ROOT_DIR" != "/opt/vps-install" ]]; then
  say_info "Copie du repo vers /opt/vps-install"
  install -d /opt
  rm -rf /opt/vps-install
  cp -a "$ROOT_DIR" /opt/vps-install
fi

# Wrapper /usr/local/bin/services : accessible depuis n'importe quel shell,
# auto-sudo si lance par un user non-root.
cat > /usr/local/bin/services <<'EOF'
#!/usr/bin/env bash
if [[ $EUID -ne 0 ]]; then
  exec sudo bash /opt/vps-install/scripts/service.sh "$@"
fi
exec bash /opt/vps-install/scripts/service.sh "$@"
EOF
chmod 755 /usr/local/bin/services

run_module "99_summary.sh"

# Services core (toujours installes sans prompt) - ils sont infrastructure,
# pas optionnels : le webhook receiver + le backup vers home.
CORE_SERVICES=(webhooks backup)
for svc in "${CORE_SERVICES[@]}"; do
  if [[ -d "$ROOT_DIR/services/$svc" ]]; then
    say_info "Auto-install du service core : $svc"
    bash /opt/vps-install/scripts/service.sh install "$svc" || \
      say_warn "Install de $svc echouee, continue quand meme."
  fi
done

# Services optionnels : menu interactif (q pour quitter = poursuivre vers
# le reboot). Plus pratique qu'un prompt yes/no par service, on voit ce qui
# est deja installe et on pilote install/update/remove sans quitter.
say_info "Menu services (q pour quitter et finir le bootstrap)"
bash /opt/vps-install/scripts/service.sh || true

# Supprime les users par defaut du provider (debian, ubuntu, ...) AVANT
# le reboot pour pas laisser de compte sudo non-utilise trainer.
run_module "98_cleanup_default_users.sh"

say_ok "Bootstrap termine. Log: $LOG"
say_warn "Reboot dans 15 secondes (Ctrl-C pour annuler)..."
for i in $(seq 15 -1 1); do
  printf "\r  %2d s..." "$i"
  sleep 1
done
printf "\r%-20s\n" ""
systemctl reboot
