#!/usr/bin/env bash
set -euo pipefail

# Deploie la cle SSH GitHub pour $VPS_USER a partir de Infisical
# (/vps/_infra/GITHUB_SSH_PRIVKEY). Optionnel : si le secret est absent,
# on skip silencieusement.
#
# Idempotent : ecrit ou ecrase la cle, dedupe known_hosts, ajoute le
# bloc SSH config seulement s'il manque.

if [[ -z "${GITHUB_SSH_PRIVKEY:-}" ]]; then
  echo "GITHUB_SSH_PRIVKEY absent de /vps/_infra, skip setup SSH GitHub."
  exit 0
fi

echo "Setup cle SSH GitHub pour $VPS_USER"

HOME_DIR="/home/$VPS_USER"
SSH_DIR="$HOME_DIR/.ssh"

install -d -m 700 -o "$VPS_USER" -g "$VPS_USER" "$SSH_DIR"

# --- Cle privee (ecrase a chaque run = rotation facile) ---
install -m 600 -o "$VPS_USER" -g "$VPS_USER" /dev/stdin "$SSH_DIR/id_ed25519" <<< "$GITHUB_SSH_PRIVKEY"

# --- known_hosts : pin github.com (evite le prompt "authenticity") ---
TMP="$(mktemp)"
[[ -f "$SSH_DIR/known_hosts" ]] && cat "$SSH_DIR/known_hosts" > "$TMP"
ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> "$TMP"
sort -u "$TMP" > "$SSH_DIR/known_hosts"
rm -f "$TMP"
chown "$VPS_USER:$VPS_USER" "$SSH_DIR/known_hosts"
chmod 644 "$SSH_DIR/known_hosts"

# --- SSH client config : bloc Host github.com si absent ---
if [[ ! -f "$SSH_DIR/config" ]] || ! grep -qE "^\s*Host\s+github\.com\s*$" "$SSH_DIR/config"; then
  cat >> "$SSH_DIR/config" <<EOF

# vps-bootstrap: route github.com vers la cle deployee depuis Infisical
Host github.com
    HostName github.com
    User git
    IdentityFile $SSH_DIR/id_ed25519
    IdentitiesOnly yes
EOF
  chown "$VPS_USER:$VPS_USER" "$SSH_DIR/config"
  chmod 600 "$SSH_DIR/config"
fi

echo "Cle SSH GitHub deployee. Test : sudo -u $VPS_USER ssh -T git@github.com"
