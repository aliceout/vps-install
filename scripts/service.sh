#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICES_DIR="$ROOT_DIR/services"
INSTALLED_DIR="/var/lib/vps-install/installed"
AGENT_BASE="/etc/infisical/agent.base.yaml"
AGENT_CONF="/etc/infisical/agent.yaml"
AGENT_FRAGMENTS_DIR="/etc/infisical/agent.d"
AGENT_TEMPLATES_DIR="/etc/infisical/templates"
SECRETS_DIR="/etc/secrets"
NGINX_CONF_DIR="/etc/nginx/conf"

if [[ $EUID -ne 0 ]]; then
  echo "Lance-moi en root: sudo bash $0"
  exit 1
fi

install -d -m 755 "$INSTALLED_DIR"

# --------- helpers ---------

read_tty() {
  local prompt="$1" var_name="$2" value=""
  if [[ -t 0 ]]; then
    read -r -p "$prompt" value
  else
    read -r -p "$prompt" value < /dev/tty
  fi
  printf -v "$var_name" '%s' "$value"
}

list_services() {
  [[ -d "$SERVICES_DIR" ]] || return 0
  find "$SERVICES_DIR" -mindepth 1 -maxdepth 1 -type d \
    -not -name '_*' -not -name '.*' \
    -printf '%f\n' | sort
}

is_installed() {
  [[ -f "$INSTALLED_DIR/$1" ]]
}

marker_info() {
  local name="$1"
  [[ -f "$INSTALLED_DIR/$name" ]] || { echo ""; return; }
  cat "$INSTALLED_DIR/$name" 2>/dev/null | head -n1
}

load_service_conf() {
  local name="$1"
  local conf="$SERVICES_DIR/$name/service.conf"
  if [[ ! -f "$conf" ]]; then
    echo "ERREUR: $conf introuvable" >&2
    return 1
  fi
  TYPE=""; DESCRIPTION=""
  # shellcheck disable=SC1090
  source "$conf"
  if [[ -z "$TYPE" ]]; then
    echo "ERREUR: TYPE non defini dans $conf" >&2
    return 1
  fi
  export TYPE DESCRIPTION
}

# Extrait les server_name d'un fichier nginx (un par ligne, dedupliques)
extract_domains_from_nginx() {
  local conf="$1"
  [[ -f "$conf" ]] || return 0
  grep -E '^\s*server_name\s+' "$conf" \
    | sed -E 's/^\s*server_name\s+//; s/;.*$//' \
    | tr ' \t' '\n\n' \
    | grep -v '^$' \
    | grep -v '^_$' \
    | sort -u
}

regen_agent_conf() {
  [[ -f "$AGENT_BASE" ]] || { echo "Agent Infisical non configure (lance bootstrap avec infisical=yes)." >&2; return 1; }
  cp "$AGENT_BASE" "$AGENT_CONF"
  shopt -s nullglob
  for f in "$AGENT_FRAGMENTS_DIR"/*.yaml; do
    cat "$f" >> "$AGENT_CONF"
  done
  shopt -u nullglob
  chmod 600 "$AGENT_CONF"
}

restart_agent_if_any() {
  if [[ -f "$AGENT_CONF" ]] && systemctl list-unit-files infisical-agent.service >/dev/null 2>&1; then
    systemctl restart infisical-agent.service || true
  fi
}

wait_for_secret_file() {
  local path="$1" timeout="${2:-60}" i=0
  while [[ ! -f "$path" ]] && (( i < timeout )); do
    sleep 1
    i=$((i+1))
  done
  [[ -f "$path" ]]
}

apply_secrets() {
  local name="$1"
  local tmpl_src="$SERVICES_DIR/$name/secrets.tmpl"
  [[ -f "$tmpl_src" ]] || return 0

  install -d -m 700 "$SECRETS_DIR"
  install -d -m 700 "$AGENT_FRAGMENTS_DIR"
  install -d -m 755 "$AGENT_TEMPLATES_DIR"

  # PROJECT_ID + ENV viennent de /etc/infisical/, INFISICAL_PATH de service.conf
  local project_id env_slug
  project_id="$(cat /etc/infisical/project-id 2>/dev/null || true)"
  env_slug="$(cat /etc/infisical/environment 2>/dev/null || true)"
  if [[ -z "$project_id" || -z "$env_slug" ]]; then
    echo "ERREUR: /etc/infisical/project-id ou /etc/infisical/environment manquant" >&2
    return 1
  fi
  local infisical_path="${INFISICAL_PATH:-/vps/$name}"

  # Substitution des placeholders dans le template
  PROJECT_ID="$project_id" \
  INFISICAL_ENV="$env_slug" \
  INFISICAL_PATH="$infisical_path" \
    envsubst '${PROJECT_ID} ${INFISICAL_ENV} ${INFISICAL_PATH}' \
      < "$tmpl_src" > "$AGENT_TEMPLATES_DIR/$name.tmpl"
  chmod 644 "$AGENT_TEMPLATES_DIR/$name.tmpl"

  cat > "$AGENT_FRAGMENTS_DIR/$name.yaml" <<EOF
  - source-path: $AGENT_TEMPLATES_DIR/$name.tmpl
    destination-path: $SECRETS_DIR/$name.env
    config:
      polling-interval: 60s
EOF
  chmod 600 "$AGENT_FRAGMENTS_DIR/$name.yaml"

  regen_agent_conf
  systemctl enable --now infisical-agent.service
  systemctl restart infisical-agent.service

  echo "Attente generation $SECRETS_DIR/$name.env..."
  if ! wait_for_secret_file "$SECRETS_DIR/$name.env" 60; then
    echo "AVERTISSEMENT: $SECRETS_DIR/$name.env pas genere (verifie l'agent: journalctl -u infisical-agent -n 50)"
    return 1
  fi
  chmod 600 "$SECRETS_DIR/$name.env" || true
  echo "Secrets injectes: $SECRETS_DIR/$name.env"
}

remove_secrets() {
  local name="$1"
  rm -f "$AGENT_FRAGMENTS_DIR/$name.yaml"
  rm -f "$AGENT_TEMPLATES_DIR/$name.tmpl"
  rm -f "$SECRETS_DIR/$name.env"
  regen_agent_conf || true
  restart_agent_if_any
}

ensure_cert() {
  local domain="$1"
  [[ -n "$domain" ]] || return 0
  if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    return 0
  fi
  if ! command -v certbot-request >/dev/null 2>&1; then
    echo "AVERTISSEMENT: certbot-request absent (module 75_certbot pas execute ?), skip cert pour $domain"
    return 0
  fi
  echo "Demande cert Let's Encrypt pour $domain..."
  if ! certbot-request "$domain"; then
    echo "AVERTISSEMENT: cert non obtenu pour $domain. Vhost deploye sans SSL operationnel."
    return 1
  fi
}

apply_nginx() {
  local name="$1"
  local vhost_src="$SERVICES_DIR/$name/nginx.conf"
  [[ -f "$vhost_src" ]] || return 0
  if [[ ! -d "$NGINX_CONF_DIR" ]]; then
    echo "Nginx pas installe, skip vhost."
    return 0
  fi

  # Recupere les domaines du vhost et demande un cert pour chacun
  local domains=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && domains+=("$d")
  done < <(extract_domains_from_nginx "$vhost_src")

  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "AVERTISSEMENT: aucun server_name trouve dans $vhost_src, skip cert."
  else
    for d in "${domains[@]}"; do
      ensure_cert "$d" || true
    done
  fi

  local dst="$NGINX_CONF_DIR/$name.conf"
  cp "$vhost_src" "$dst"
  chmod 644 "$dst"
  if nginx -t 2>/dev/null; then
    systemctl reload nginx || true
    echo "Vhost nginx installe: $dst (domaines: ${domains[*]:-aucun})"
  else
    echo "ERREUR: nginx -t KO, vhost laisse en place mais non recharge"
    nginx -t || true
  fi
}

remove_nginx() {
  local name="$1"
  rm -f "$NGINX_CONF_DIR/$name.conf"
  if command -v nginx >/dev/null 2>&1 && nginx -t 2>/dev/null; then
    systemctl reload nginx || true
  fi
}

run_service_script() {
  local name="$1" action="$2"
  local script="$SERVICES_DIR/$name/install.sh"
  if [[ ! -f "$script" ]]; then
    echo "INFO: pas de $script, skip action=$action"
    return 0
  fi
  ACTION="$action" \
  SERVICE_NAME="$name" \
  SERVICE_DIR="$SERVICES_DIR/$name" \
  SECRETS_FILE="$SECRETS_DIR/$name.env" \
    bash "$script"
}

mark_installed() {
  local name="$1"
  date -Iseconds > "$INSTALLED_DIR/$name"
}

mark_removed() {
  rm -f "$INSTALLED_DIR/$1"
}

# --------- actions ---------

action_list() {
  local any=0
  echo "Services disponibles:"
  while IFS= read -r s; do
    any=1
    local state="    " extra=""
    if is_installed "$s"; then state="[x] "; extra=" (installe: $(marker_info "$s"))"; else state="[ ] "; fi
    local type="?"
    if [[ -f "$SERVICES_DIR/$s/service.conf" ]]; then
      type=$(grep -E '^TYPE=' "$SERVICES_DIR/$s/service.conf" | head -n1 | cut -d= -f2- | tr -d '"' || true)
    fi
    printf '  %s%-25s %-15s%s\n' "$state" "$s" "($type)" "$extra"
  done < <(list_services)
  [[ "$any" -eq 0 ]] && echo "  (aucun) - ajoute un service dans $SERVICES_DIR/<nom>/"
}

action_install() {
  local name="$1" force="${2:-0}"
  [[ -d "$SERVICES_DIR/$name" ]] || { echo "ERREUR: service '$name' introuvable"; return 1; }

  if is_installed "$name" && [[ "$force" -ne 1 ]]; then
    echo "'$name' deja installe ($(marker_info "$name")). Relance avec --force pour reinstaller."
    return 0
  fi

  load_service_conf "$name"
  echo "=== Install $name (type=$TYPE) ==="

  apply_secrets "$name" || true
  apply_nginx "$name"
  run_service_script "$name" "install"
  mark_installed "$name"

  echo "=== $name installe ==="
}

action_update() {
  local name="$1"
  [[ -d "$SERVICES_DIR/$name" ]] || { echo "ERREUR: service '$name' introuvable"; return 1; }
  if ! is_installed "$name"; then
    echo "'$name' pas installe, lance 'install' a la place."
    return 1
  fi
  load_service_conf "$name"
  echo "=== Update $name ==="
  apply_secrets "$name" || true
  apply_nginx "$name"
  run_service_script "$name" "update"
  mark_installed "$name"
  echo "=== $name mis a jour ==="
}

action_remove() {
  local name="$1"
  [[ -d "$SERVICES_DIR/$name" ]] || { echo "ERREUR: service '$name' introuvable"; return 1; }
  load_service_conf "$name" || true
  echo "=== Remove $name ==="
  run_service_script "$name" "remove"
  remove_nginx "$name"
  remove_secrets "$name"
  mark_removed "$name"
  echo "=== $name supprime ==="
}

action_status() {
  local name="$1"
  [[ -d "$SERVICES_DIR/$name" ]] || { echo "ERREUR: service '$name' introuvable"; return 1; }
  load_service_conf "$name" || true
  if is_installed "$name"; then
    echo "$name: INSTALLE ($(marker_info "$name"))"
  else
    echo "$name: NON INSTALLE"
  fi
  run_service_script "$name" "status" || true
}

action_menu() {
  while true; do
    echo
    action_list
    echo
    echo "Actions: (i)nstall, (u)pdate, (r)emove, (s)tatus, (q)uit"
    read_tty "Choix: " choice
    choice="${choice,,}"
    case "$choice" in
      q|quit|exit) return 0 ;;
      i|u|r|s)
        read_tty "Nom du service: " target
        target="${target// }"
        [[ -z "$target" ]] && continue
        case "$choice" in
          i)
            local force=0
            if is_installed "$target"; then
              read_tty "'$target' deja installe, forcer ? [o/N]: " f
              [[ "${f,,}" =~ ^(o|oui|y|yes)$ ]] && force=1 || continue
            fi
            action_install "$target" "$force" || true
            ;;
          u) action_update "$target" || true ;;
          r)
            read_tty "Confirmer suppression de '$target' ? [o/N]: " c
            [[ "${c,,}" =~ ^(o|oui|y|yes)$ ]] && action_remove "$target" || echo "Annule."
            ;;
          s) action_status "$target" || true ;;
        esac
        ;;
      *) echo "Choix invalide." ;;
    esac
  done
}

# --------- CLI ---------

usage() {
  cat <<EOF
Usage: sudo bash $0 [commande] [args]

Commandes:
  (aucune)                 menu interactif
  list                     liste les services (installes marques [x])
  install <nom> [--force]  installe un service
  update <nom>             met a jour un service
  remove <nom>             desinstalle un service
  status <nom>             statut d'un service
EOF
}

main() {
  if [[ $# -eq 0 ]]; then
    action_menu
    return
  fi
  local cmd="$1"; shift
  case "$cmd" in
    list) action_list ;;
    install)
      [[ $# -ge 1 ]] || { usage; exit 1; }
      local force=0
      local names=()
      for a in "$@"; do
        case "$a" in
          --force) force=1 ;;
          *) names+=("$a") ;;
        esac
      done
      for n in "${names[@]}"; do
        action_install "$n" "$force"
      done
      ;;
    update)
      [[ $# -ge 1 ]] || { usage; exit 1; }
      for n in "$@"; do action_update "$n"; done
      ;;
    remove)
      [[ $# -ge 1 ]] || { usage; exit 1; }
      for n in "$@"; do action_remove "$n"; done
      ;;
    status)
      [[ $# -ge 1 ]] || { usage; exit 1; }
      action_status "$1"
      ;;
    -h|--help|help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
