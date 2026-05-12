#!/usr/bin/env bash
set -euo pipefail

echo "Creation user + sudo: $VPS_USER"
apt-get install -y sudo

if ! id "$VPS_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/bin/zsh "$VPS_USER"
fi
usermod -aG sudo "$VPS_USER"

if [[ -n "${VPS_USER_PASSWORD:-}" ]]; then
  echo "Set password pour $VPS_USER"
  printf '%s:%s\n' "$VPS_USER" "$VPS_USER_PASSWORD" | chpasswd
fi

echo "Setup SSH authorized_keys"
install -d -m 700 "/home/$VPS_USER/.ssh"
# SSH_PUBKEY peut contenir plusieurs cles separees par \n
printf '%s\n' "$SSH_PUBKEY" > "/home/$VPS_USER/.ssh/authorized_keys"
chown -R "$VPS_USER:$VPS_USER" "/home/$VPS_USER/.ssh"
chmod 600 "/home/$VPS_USER/.ssh/authorized_keys"

echo "Hardening sshd_config (port $SSH_PORT, no root, no password)"
apt-get install -y openssh-server

SSHD="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN="${SSHD_DROPIN_DIR}/00-vps-hardening.conf"

cp -a "$SSHD" "${SSHD}.bak.$(date +%F_%H%M%S)"

# Strategie : un drop-in 00-vps-hardening.conf dans /etc/ssh/sshd_config.d/.
# Sur Debian 13 (et toute distro recente), les defauts cloud-init / vendor
# sont dans des drop-ins (ex: 50-cloud-init.conf) que sed sur sshd_config ne
# touche pas - on durcissait dans le vide. Le prefixe '00-' garantit que
# notre drop-in est lu en PREMIER (sshd applique 'first match wins').
#
# On garde quand meme le sed sur sshd_config (defense en profondeur) pour
# les setups plus anciens ou les options ne supporteraient pas les drop-ins.

install -d -m 755 "$SSHD_DROPIN_DIR"

# S'assure que le main sshd_config charge bien les drop-ins (le defaut Debian
# l'inclut, mais on couvre les configs custom anciennes qui ne l'auraient pas).
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD"; then
  sed -i '1iInclude /etc/ssh/sshd_config.d/*.conf' "$SSHD"
fi

cat > "$SSHD_DROPIN" <<EOF
# Genere par vps-install (modules/10_user_ssh.sh) - ne pas editer a la main.
# Charge en premier ('00-') pour gagner sur les drop-ins distro/cloud-init.
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding no
UsePAM yes
AllowUsers ${VPS_USER}
EOF
chmod 644 "$SSHD_DROPIN"

# Defense en profondeur : sed sur le main sshd_config aussi. Inoffensif si
# le drop-in seul fait le job, utile si une distro ancienne ignore le dir.
sed -i -E \
  -e 's/^[# ]*Port .*/Port '"$SSH_PORT"'/' \
  -e 's/^[# ]*PermitRootLogin .*/PermitRootLogin no/' \
  -e 's/^[# ]*PermitEmptyPasswords .*/PermitEmptyPasswords no/' \
  -e 's/^[# ]*PasswordAuthentication .*/PasswordAuthentication no/' \
  -e 's/^[# ]*KbdInteractiveAuthentication .*/KbdInteractiveAuthentication no/' \
  -e 's/^[# ]*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication no/' \
  -e 's/^[# ]*MaxAuthTries .*/MaxAuthTries 3/' \
  -e 's/^[# ]*LoginGraceTime .*/LoginGraceTime 20/' \
  -e 's/^[# ]*ClientAliveInterval .*/ClientAliveInterval 300/' \
  -e 's/^[# ]*ClientAliveCountMax .*/ClientAliveCountMax 2/' \
  -e 's/^[# ]*X11Forwarding .*/X11Forwarding no/' \
  -e 's/^[# ]*AllowTcpForwarding .*/AllowTcpForwarding no/' \
  -e 's/^[# ]*UsePAM .*/UsePAM yes/' \
  "$SSHD"

sshd -t

# Verifie que la config EFFECTIVE (apres merge de tous les drop-ins) matche
# nos attentes - sinon un drop-in cloud-init prioritaire ou un Match block
# pourrait neutraliser notre hardening sans qu'on le voie.
effective="$(sshd -T -C user="$VPS_USER" 2>/dev/null || sshd -T 2>/dev/null || true)"
if [[ -n "$effective" ]]; then
  fail=0
  while IFS=: read -r k v; do
    actual="$(printf '%s\n' "$effective" | awk -v k="$k" 'tolower($1) == k { print $2 }' | head -n1)"
    if [[ "$actual" != "$v" ]]; then
      echo "ERREUR: sshd $k effectif='$actual', attendu='$v' (un drop-in concurrent override le notre)" >&2
      fail=1
    fi
  done <<EOF
permitrootlogin:no
passwordauthentication:no
permitemptypasswords:no
kbdinteractiveauthentication:no
port:${SSH_PORT}
EOF
  if [[ $fail -ne 0 ]]; then
    echo "Ne redemarre pas sshd : la config effective est plus permissive que demandee." >&2
    echo "Inspecte: sshd -T -C user=$VPS_USER ; et ls /etc/ssh/sshd_config.d/" >&2
    exit 1
  fi
fi

systemctl restart ssh

echo "IMPORTANT: garde cette session ouverte. Ensuite teste: ssh -p $SSH_PORT $VPS_USER@<ip>"