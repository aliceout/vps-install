#!/usr/bin/env bash
set -euo pipefail

# Deploie les cles SSH des forges git (GitHub, GitLab) pour $VPS_USER
# depuis Infisical (/vps/_infra/<PROVIDER>_SSH_PRIVKEY).
#
# Providers supportes (pour en ajouter : edit PROVIDERS ci-dessous + ajoute
# la cle <NAME>_SSH_PRIVKEY dans INFRA_KEYS de bootstrap.sh) :
#   - GITHUB_SSH_PRIVKEY -> github.com
#   - GITLAB_SSH_PRIVKEY -> gitlab.com
#
# Strategie :
#   - ~/.ssh/config.d/vps-bootstrap-git regenere a chaque run (zero drift)
#   - ~/.ssh/config contient Include ~/.ssh/config.d/* (ajoute une fois)
#   - cles deployees sous ~/.ssh/id_ed25519_<provider>
#   - les providers sans cle fournie sont silencieusement skippes (et leur
#     cle supprimee si elle trainait)

# Liste: "NOM_VAR_ENV host_ssh" (pairs separees par virgule)
PROVIDERS="GITHUB github.com,GITLAB gitlab.com"

HOME_DIR="/home/$VPS_USER"
SSH_DIR="$HOME_DIR/.ssh"
CONFIG_FILE="$SSH_DIR/config"
CONFIG_D="$SSH_DIR/config.d"
GIT_CONFIG_FRAGMENT="$CONFIG_D/vps-bootstrap-git"

install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "$SSH_DIR"
install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "$CONFIG_D"

touch "$CONFIG_FILE"
chown "$VPS_USER:$VPS_USER" "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# S'assure que ~/.ssh/config commence par l'Include
if ! grep -qE "^\s*Include\s+$SSH_DIR/config\.d/\*" "$CONFIG_FILE"; then
  TMP_CFG="$(mktemp)"
  {
    printf '# vps-bootstrap: Include dynamique des fragments\n'
    printf 'Include %s/*\n\n' "$CONFIG_D"
    cat "$CONFIG_FILE"
  } > "$TMP_CFG"
  mv "$TMP_CFG" "$CONFIG_FILE"
  chown "$VPS_USER:$VPS_USER" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
fi

# Purge un eventuel bloc legacy laisse par l'ancien 15_github_ssh.sh.
# Heuristique: commentaire "vps-bootstrap: route github.com" + 5 lignes
# du bloc Host qui suivent.
if grep -qE '^# vps-bootstrap: route github\.com' "$CONFIG_FILE"; then
  TMP_CFG="$(mktemp)"
  awk '
    /^# vps-bootstrap: route github\.com/ { skip=6; next }
    skip>0 { skip--; next }
    { print }
  ' "$CONFIG_FILE" > "$TMP_CFG"
  mv "$TMP_CFG" "$CONFIG_FILE"
  chown "$VPS_USER:$VPS_USER" "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  echo "Ancien bloc Host github.com (legacy) retire."
fi

# Deploie chaque provider configure
KH_TMP="$(mktemp)"
[[ -s "$SSH_DIR/known_hosts" ]] && cat "$SSH_DIR/known_hosts" > "$KH_TMP"

CFG_CONTENT=""
CFG_CONTENT+="# Genere par modules/15_git_ssh.sh - NE PAS EDITER A LA MAIN"$'\n'
CFG_CONTENT+="# (regenere a chaque bootstrap)"$'\n\n'

IFS=',' read -r -a PROVIDER_LIST <<< "$PROVIDERS"
configured_any=0
for pair in "${PROVIDER_LIST[@]}"; do
  pair="$(echo "$pair" | xargs)"      # trim
  name="${pair% *}"
  host="${pair#* }"
  name_lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  key_var="${name}_SSH_PRIVKEY"
  key_path="$SSH_DIR/id_ed25519_${name_lower}"
  privkey="${!key_var:-}"

  if [[ -z "$privkey" ]]; then
    rm -f "$key_path"
    continue
  fi

  configured_any=1
  echo "Deploie cle SSH ${host} (source: /vps/_infra/${key_var})"
  install -m 600 -o "$VPS_USER" -g "$VPS_USER" /dev/stdin "$key_path" <<< "$privkey"

  ssh-keyscan -t ed25519,rsa "$host" 2>/dev/null >> "$KH_TMP" || true

  CFG_CONTENT+="Host ${host}"$'\n'
  CFG_CONTENT+="    HostName ${host}"$'\n'
  CFG_CONTENT+="    User git"$'\n'
  CFG_CONTENT+="    IdentityFile ${key_path}"$'\n'
  CFG_CONTENT+="    IdentitiesOnly yes"$'\n\n'
done

if [[ "$configured_any" -eq 0 ]]; then
  echo "Aucune cle SSH git configuree (ni GITHUB_SSH_PRIVKEY ni GITLAB_SSH_PRIVKEY dans /vps/_infra), skip."
  # On ecrit quand meme un fragment vide pour effacer l'ancien contenu.
  : > "$GIT_CONFIG_FRAGMENT"
else
  printf '%s' "$CFG_CONTENT" > "$GIT_CONFIG_FRAGMENT"
fi
chown "$VPS_USER:$VPS_USER" "$GIT_CONFIG_FRAGMENT"
chmod 600 "$GIT_CONFIG_FRAGMENT"

sort -u "$KH_TMP" > "$SSH_DIR/known_hosts"
rm -f "$KH_TMP"
chown "$VPS_USER:$VPS_USER" "$SSH_DIR/known_hosts"
chmod 644 "$SSH_DIR/known_hosts"

# Tests affiches (uniquement les providers configures)
for pair in "${PROVIDER_LIST[@]}"; do
  pair="$(echo "$pair" | xargs)"
  name="${pair% *}"
  host="${pair#* }"
  key_var="${name}_SSH_PRIVKEY"
  [[ -n "${!key_var:-}" ]] && echo "Test : sudo -u $VPS_USER ssh -T git@${host}"
done
