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

# Coloration des lignes ERREUR / AVERTISSEMENT pour qu'elles ressortent
# au milieu du flux verbeux de install.sh + apt + docker. Couvre stdout
# ET stderr de service.sh + tous ses sous-process (install.sh herite des
# FDs). Activee uniquement si stdout est un TTY -> cron/logs restent
# clean (pas de codes ANSI \033[xx;m).
colorize_output() {
  awk '
    /^ERREUR/        { printf "\033[1;31m%s\033[0m\n", $0; fflush(); next }
    /^AVERTISSEMENT/ { printf "\033[1;33m%s\033[0m\n", $0; fflush(); next }
    /^=== .* ===$/   { printf "\033[1;36m%s\033[0m\n", $0; fflush(); next }
                     { print; fflush() }
  '
}
if [[ -t 1 ]]; then
  exec > >(colorize_output) 2> >(colorize_output >&2)
fi

# VPS_USER (user non-root principal) : chargé depuis le fichier persiste par
# 35_infisical.sh. Transmis ensuite aux install.sh des services.
if [[ -z "${VPS_USER:-}" && -s /etc/infisical/vps-user ]]; then
  VPS_USER="$(cat /etc/infisical/vps-user)"
fi
export VPS_USER

# HOST_TYPE (vps|server) : ecrit par bootstrap.sh dans /etc/infisical/host-type.
# Utilise par les service.conf qui ont besoin de scoper leur INFISICAL_PATH par
# host (ex: webhooks dont l'ADDRESS differe entre vps et server).
# Toujours initialise (eventuellement vide) pour ne pas casser le source d'un
# service.conf qui le reference sous set -u.
HOST_TYPE="${HOST_TYPE:-}"
if [[ -z "$HOST_TYPE" && -s /etc/infisical/host-type ]]; then
  HOST_TYPE="$(cat /etc/infisical/host-type)"
fi
export HOST_TYPE

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
  # Write-then-rename : si on ecrivait directement dans $AGENT_CONF, un restart
  # de l'agent pendant la concat pourrait le faire charger un YAML tronque (et
  # crasher -> tous les secrets de tous les services indisponibles).
  local tmp="${AGENT_CONF}.new.$$"
  cp "$AGENT_BASE" "$tmp"
  shopt -s nullglob
  for f in "$AGENT_FRAGMENTS_DIR"/*.yaml; do
    cat "$f" >> "$tmp"
  done
  shopt -u nullglob
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "ERREUR: agent.yaml temp vide, refuse de remplacer $AGENT_CONF" >&2
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$AGENT_CONF"
}

restart_agent_if_any() {
  if [[ -f "$AGENT_CONF" ]] && systemctl list-unit-files infisical-agent.service >/dev/null 2>&1; then
    systemctl restart infisical-agent.service || true
  fi
}

# Considere un env file Infisical "valide" : non vide ET contenant au moins une
# ligne KEY=value. L'agent peut creer un fichier vide ou ne contenant que des
# blancs si le path Infisical est inconnu / vide / sans permission - on doit
# detecter ces cas plutot que continuer avec un env file inutilisable.
_secret_file_valid() {
  local path="$1"
  [[ -s "$path" ]] || return 1
  grep -qE '^[A-Z_][A-Z0-9_]*=' "$path"
}

wait_for_secret_file() {
  local path="$1" timeout="${2:-60}" i=0 had_file=0
  while (( i < timeout )); do
    if _secret_file_valid "$path"; then
      return 0
    fi
    [[ -f "$path" ]] && had_file=1
    sleep 1
    i=$((i+1))
  done
  if (( had_file == 0 )); then
    echo "  -> $path n'a jamais ete cree par l'agent (verifie journalctl -u infisical-agent)." >&2
  else
    echo "  -> $path cree mais aucune ligne KEY=value detectee. Verifie INFISICAL_PATH et la couverture machine identity." >&2
  fi
  return 1
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
  local infisical_path="${INFISICAL_PATH:-/services/$name}"

  local tmpl_target="$AGENT_TEMPLATES_DIR/$name.tmpl"
  local frag_target="$AGENT_FRAGMENTS_DIR/$name.yaml"
  local secret_target="$SECRETS_DIR/$name.env"

  # Genere le contenu attendu dans des tempfiles, puis compare a l'etat actuel.
  # Sans cette comparaison, chaque 'services update <svc>' restart l'agent meme
  # quand rien n'a change cote templates -> cascade de restarts qui invalident
  # tous les /etc/secrets/*.env en cours d'usage par d'autres services.
  local new_tmpl new_frag
  new_tmpl="$(mktemp)"
  new_frag="$(mktemp)"

  PROJECT_ID="$project_id" \
  INFISICAL_ENV="$env_slug" \
  INFISICAL_PATH="$infisical_path" \
    envsubst '${PROJECT_ID} ${INFISICAL_ENV} ${INFISICAL_PATH}' \
      < "$tmpl_src" > "$new_tmpl"

  cat > "$new_frag" <<EOF
  - source-path: $tmpl_target
    destination-path: $secret_target
    config:
      polling-interval: 60s
EOF

  local restart_needed=0
  if ! cmp -s "$new_tmpl" "$tmpl_target" 2>/dev/null; then
    mv "$new_tmpl" "$tmpl_target"
    chmod 644 "$tmpl_target"
    restart_needed=1
  else
    rm -f "$new_tmpl"
  fi
  if ! cmp -s "$new_frag" "$frag_target" 2>/dev/null; then
    mv "$new_frag" "$frag_target"
    chmod 600 "$frag_target"
    restart_needed=1
  else
    rm -f "$new_frag"
  fi
  # Sink absent ou corrompu : faut restart pour le (re)generer
  _secret_file_valid "$secret_target" || restart_needed=1

  if (( restart_needed == 0 )); then
    echo "Secrets $name : templates et sink inchanges, skip restart agent."
  else
    regen_agent_conf
    # Supprime l'ancien env file avant restart, pour que wait_for_secret_file
    # bloque jusqu'a ce que l'agent regenere depuis le template a jour. Sinon,
    # si le template a change mais que le fichier rendu reste valide, le wait
    # retournerait immediatement sur du contenu stale.
    rm -f "$secret_target"
    systemctl enable --now infisical-agent.service
    systemctl restart infisical-agent.service

    echo "Attente generation $secret_target..."
    if ! wait_for_secret_file "$secret_target" 60; then
      echo "ERREUR: $secret_target non genere ou vide." >&2
      return 1
    fi
  fi

  # Le hook script de chaque service tourne en tant que VPS_USER (via runuser),
  # il doit pouvoir lire son env file. /etc/secrets/ reste en 700, mais on
  # rend le fichier lisible par le groupe VPS_USER (chgrp + 640).
  if [[ -n "${VPS_USER:-}" ]]; then
    chgrp "$VPS_USER" "$secret_target" 2>/dev/null || true
    chmod 640 "$secret_target" || true
    chgrp "$VPS_USER" "$SECRETS_DIR" 2>/dev/null || true
    chmod 750 "$SECRETS_DIR" || true
  else
    chmod 600 "$secret_target" || true
  fi
  echo "Secrets injectes: $secret_target"
}

remove_secrets() {
  local name="$1"
  rm -f "$AGENT_FRAGMENTS_DIR/$name.yaml"
  rm -f "$AGENT_TEMPLATES_DIR/$name.tmpl"
  rm -f "$SECRETS_DIR/$name.env"
  regen_agent_conf || true
  restart_agent_if_any
}

maybe_restore_data() {
  # Si service.conf declare RESTORE_ON_INSTALL=yes ET DATA_DIR, on tente
  # une restore du dernier snapshot restic sur ce path. Skip si backup-restore
  # n'est pas installe, ou si le dossier contient deja des donnees.
  local name="$1"
  local conf="$SERVICES_DIR/$name/service.conf"
  [[ -f "$conf" ]] || return 0

  # Le `|| true` evite que grep sans match (rc=1) + pipefail + set -e ne
  # tue action_install en plein vol avant run_service_script.
  local restore_flag="" data_dir=""
  restore_flag="$(grep -E '^RESTORE_ON_INSTALL=' "$conf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'"'" || true)"
  data_dir="$(grep -E '^DATA_DIR=' "$conf" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"'"'" || true)"

  # Remplace $VPS_USER / ${VPS_USER} si present dans la valeur
  data_dir="${data_dir//\$VPS_USER/$VPS_USER}"
  data_dir="${data_dir//\$\{VPS_USER\}/$VPS_USER}"

  [[ "$restore_flag" == "yes" || "$restore_flag" == "true" || "$restore_flag" == "1" ]] || return 0
  [[ -n "$data_dir" ]] || { echo "RESTORE_ON_INSTALL sans DATA_DIR, skip"; return 0; }

  if ! command -v backup-restore >/dev/null 2>&1; then
    echo "backup-restore absent (service 'backup' pas installe), skip restore."
    return 0
  fi

  echo "Tentative de restore des donnees pour $name (target: $data_dir)..."
  backup-restore "$data_dir" || echo "AVERTISSEMENT: restore KO (le service demarrera avec un dossier vide)."
}

ensure_cert() {
  local fqdn="$1"
  local apex="${2:-}"
  local provider="${3:-}"
  local token_name="${4:-}"
  [[ -n "$fqdn" ]] || return 0

  # Apex : soit fourni par le caller (lu depuis DOMAIN dans /etc/secrets/), soit
  # derive en strippant le 1er label du FQDN (cas sub.apex). Pour un FQDN qui
  # EST deja l'apex, le strip donne le TLD et LE refuse : il FAUT passer
  # l'apex explicitement dans ce cas.
  if [[ -z "$apex" ]]; then
    apex="${fqdn#*.}"
  fi

  if ! command -v certbot-wildcard >/dev/null 2>&1; then
    echo "AVERTISSEMENT: certbot-wildcard absent (module 75_certbot pas execute ?), skip cert pour $apex"
    return 0
  fi

  if [[ -z "$provider" || -z "$token_name" ]]; then
    echo "AVERTISSEMENT: DNS_PROVIDER et DNS_TOKEN_NAME manquants dans /etc/secrets/, skip cert pour $apex."
    echo "  Ajoute dans Infisical /services/<name>/ : DNS_PROVIDER=<infomaniak|ovh> + DNS_TOKEN_NAME=<label>"
    return 1
  fi

  # certbot-wildcard est idempotent : demande le cert si absent, skip si
  # present (mais reecrit /etc/nginx/certificat/<apex>.conf dans les deux cas).
  if ! certbot-wildcard "$apex" "$provider" "$token_name"; then
    echo "AVERTISSEMENT: cert non obtenu pour $apex ($provider:$token_name). Vhost deploye sans SSL."
    return 1
  fi
}

ensure_dns() {
  local fqdn="$1"
  [[ -n "$fqdn" ]] || return 0
  # dns-sync gere le choix du provider/token en lisant /etc/certbot/providers.conf
  # automatiquement. Pas besoin de passer provider/token ici.
  if ! command -v dns-sync >/dev/null 2>&1; then
    return 0
  fi
  echo "Sync record DNS A pour $fqdn..."
  dns-sync "$fqdn" || echo "AVERTISSEMENT: DNS sync echoue pour $fqdn (le service sera injoignable le temps que tu corriges)."
}

apply_nginx() {
  local name="$1"
  local vhost_src="$SERVICES_DIR/$name/nginx.conf"
  [[ -f "$vhost_src" ]] || return 0
  if [[ ! -d "$NGINX_CONF_DIR" ]]; then
    echo "Nginx pas installe, skip vhost."
    return 0
  fi

  # Re-sync les includes nginx depuis le repo (idempotent) : 50_nginx.sh ne
  # tourne qu'au bootstrap initial, donc sans ce sync les modifs de
  # nginx/include/*.conf et nginx/conf/common.conf restent invisibles
  # sur le VPS. Couvre le cas typique : ajout d'une directive http (ex
  # limit_req_zone) qui doit etre vue avant que le vhost qui la reference
  # soit charge.
  if [[ -d "$ROOT_DIR/nginx/include" ]]; then
    install -d /etc/nginx/include
    cp -a "$ROOT_DIR/nginx/include/." /etc/nginx/include/
  fi
  if [[ -f "$ROOT_DIR/nginx/conf/common.conf" && -d /etc/nginx/conf.d ]]; then
    cp -a "$ROOT_DIR/nginx/conf/common.conf" /etc/nginx/conf.d/common.conf
  fi

  # Rendu du vhost : substitue __KEY__ par la valeur depuis /etc/secrets/<name>.env
  # (synce par l'agent Infisical depuis /services/<name>/).
  local rendered
  rendered="$(mktemp)"
  cp "$vhost_src" "$rendered"

  local env_file="$SECRETS_DIR/$name.env"
  if [[ -f "$env_file" ]]; then
    # Substitution en une passe awk : evite la cascade de sed -i + le quoting
    # shell hazardeux des valeurs (caracteres |, &, \, voire newline incrustes
    # dans un secret). Awk lit l'env file, construit une map, puis remplace
    # __KEY__ par la valeur literale (& et \ sont reechappes pour gsub).
    local rendered_new
    rendered_new="$(mktemp)"
    if ! awk \
      -v envf="$env_file" \
      -v sq="'" \
      '
      # Remplacement literal via index/substr : pas de regex, pas de pieges
      # autour de & ou \\ comme avec gsub (ou la chaine de remplacement est
      # interpretee). On accepte donc nimporte quelle valeur tel quel.
      function replace_all(haystack, needle, repl,    out, pos) {
        out = ""
        while ((pos = index(haystack, needle)) > 0) {
          out = out substr(haystack, 1, pos - 1) repl
          haystack = substr(haystack, pos + length(needle))
        }
        return out haystack
      }
      BEGIN {
        while ((getline line < envf) > 0) {
          if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) continue
          eq = index(line, "=")
          if (eq == 0) continue
          key = substr(line, 1, eq-1)
          val = substr(line, eq+1)
          if (length(val) >= 1) {
            c1 = substr(val, 1, 1)
            cN = substr(val, length(val), 1)
            # Si la valeur commence par un quote mais ne finit pas par le meme,
            # cest probablement une valeur multi-ligne (template Infisical
            # KEY=quote {{ .Value }} quote rend des newlines literales pour des
            # secrets multi-lignes). On skip plutot que polluer le vhost.
            if (c1 == sq && cN != sq) {
              printf "AVERTISSEMENT: cle %s : valeur multi-ligne ou guillemets desequilibres, skip.\n", key > "/dev/stderr"
              continue
            }
            if (c1 == "\"" && cN != "\"") {
              printf "AVERTISSEMENT: cle %s : valeur multi-ligne ou guillemets desequilibres, skip.\n", key > "/dev/stderr"
              continue
            }
            if (length(val) >= 2 && ((c1 == sq && cN == sq) || (c1 == "\"" && cN == "\""))) {
              val = substr(val, 2, length(val)-2)
            }
          }
          vars[key] = val
        }
        close(envf)
      }
      {
        line = $0
        for (k in vars) {
          line = replace_all(line, "__" k "__", vars[k])
        }
        print line
      }
      ' "$rendered" > "$rendered_new"; then
      rm -f "$rendered" "$rendered_new"
      echo "ERREUR: substitution awk KO pour $vhost_src" >&2
      return 1
    fi
    mv "$rendered_new" "$rendered"
  fi

  # Verifie qu'aucun placeholder __KEY__ ne subsiste apres rendu : sinon
  # nginx -t planterait (ex: include /etc/nginx/certificat/__DOMAIN__.conf
  # avec __DOMAIN__ litteral si DOMAIN manque dans Infisical). On bail
  # AVANT d'ecrire le vhost pour ne pas casser un vhost qui marchait avant
  # et eviter le mv .broken + reload nginx de la branche d'erreur en aval.
  #
  # NB : grep -qE en gate avant l'extraction. Faire directement
  # unresolved=$(grep -oE ... | sort | tr) laisse $?=1 quand grep ne matche
  # rien (cas nominal), parce que pipefail propage le rc=1 du grep -- bash
  # n'applique pas set -e aux variable assignments donc on n'exit pas, mais
  # le $?=1 residuel peut induire en erreur tout code futur qui le teste.
  if grep -qE '__[A-Z][A-Z0-9_]*__' "$rendered"; then
    local unresolved
    unresolved="$(grep -oE '__[A-Z][A-Z0-9_]*__' "$rendered" | sort -u | tr '\n' ' ')"
    echo "AVERTISSEMENT: placeholders non resolus dans $vhost_src apres templating: ${unresolved% }"
    echo "  Verifie que ces cles existent dans Infisical (${INFISICAL_PATH:-/services/$name}) puis relance."
    echo "  Vhost non installe (le precedent reste en place s'il existait)."
    rm -f "$rendered"
    return 1
  fi

  # Recupere les domaines du vhost RENDU (apres substitution) pour DNS + cert
  local domains=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && domains+=("$d")
  done < <(extract_domains_from_nginx "$rendered")

  # Extrait DOMAIN, DNS_PROVIDER et DNS_TOKEN_NAME depuis l'env file.
  # DOMAIN : apex du vhost (pour calculer l'apex correct quand FQDN == apex).
  # DNS_PROVIDER / DNS_TOKEN_NAME : requis pour obtenir un cert. Pointent sur
  # /certbot/<provider>/<name> dans Infisical.
  local apex_from_env="" dns_provider="" dns_token_name=""
  if [[ -f "$env_file" ]]; then
    apex_from_env="$(grep -E '^DOMAIN=' "$env_file" | head -n1 | cut -d= -f2- | tr -d ' "'"'" || true)"
    dns_provider="$(grep -E '^DNS_PROVIDER=' "$env_file" | head -n1 | cut -d= -f2- | tr -d ' "'"'" || true)"
    dns_token_name="$(grep -E '^DNS_TOKEN_NAME=' "$env_file" | head -n1 | cut -d= -f2- | tr -d ' "'"'" || true)"
  fi

  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "AVERTISSEMENT: aucun server_name dans $vhost_src, skip DNS/cert."
  else
    # Ordre important : ensure_cert AVANT ensure_dns.
    # ensure_cert ecrit /etc/certbot/providers.conf (apex -> provider:token) et
    # regen les ini. dns-sync lit ce fichier pour choisir le bon token. Faire
    # l'inverse -> sur un premier install dns-sync ne trouve pas d'entree pour
    # l'apex et skip.
    for d in "${domains[@]}"; do
      ensure_cert "$d" "$apex_from_env" "$dns_provider" "$dns_token_name" || true
      ensure_dns  "$d" || true
    done
  fi

  local dst="$NGINX_CONF_DIR/$name.conf"
  cp "$rendered" "$dst"
  chmod 644 "$dst"
  rm -f "$rendered"

  if nginx -t 2>/dev/null; then
    systemctl reload nginx || true
    echo "Vhost nginx installe: $dst (domaines: ${domains[*]:-aucun})"
  else
    # Vhost casse : on le degage pour ne pas bloquer les autres au prochain reload
    echo "ERREUR: nginx -t KO apres ajout de $dst. Vhost retire pour preserver nginx."
    nginx -t 2>&1 | sed 's/^/  /' || true
    mv "$dst" "${dst}.broken"
    echo "Vhost casse archive en ${dst}.broken (corrige et renomme pour reessayer)."
    nginx -t 2>/dev/null && systemctl reload nginx || true
    return 1
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
  VPS_USER="${VPS_USER:-}" \
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
  if [[ "$any" -eq 0 ]]; then
    echo "  (aucun) - ajoute un service dans $SERVICES_DIR/<nom>/"
  fi
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

  if ! apply_secrets "$name"; then
    echo "ERREUR: apply_secrets KO pour $name, abort (l'agent Infisical n'a pas pu rendre les secrets)." >&2
    return 1
  fi
  apply_nginx "$name"
  maybe_restore_data "$name"
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
  if ! apply_secrets "$name"; then
    echo "ERREUR: apply_secrets KO pour $name, abort (l'agent Infisical n'a pas pu rendre les secrets)." >&2
    return 1
  fi
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
