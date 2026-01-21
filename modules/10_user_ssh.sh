#!/usr/bin/env bash
set -euo pipefail

echo "Creation user + sudo: $VPS_USER"
apt-get install -y sudo

if ! id "$VPS_USER" >/dev/null 2>&1; then
  useradd -m -s /usr/bin/zsh "$VPS_USER"
fi
usermod -aG sudo "$VPS_USER"

echo "Setup SSH authorized_keys"
install -d -m 700 "/home/$VPS_USER/.ssh"
printf '%s\n' "$SSH_PUBKEY" > "/home/$VPS_USER/.ssh/authorized_keys"
chown -R "$VPS_USER:$VPS_USER" "/home/$VPS_USER/.ssh"
chmod 600 "/home/$VPS_USER/.ssh/authorized_keys"

echo "Hardening sshd_config (port $SSH_PORT, no root, no password)"
apt-get install -y openssh-server

SSHD="/etc/ssh/sshd_config"
cp -a "$SSHD" "${SSHD}.bak.$(date +%F_%H%M%S)"

# Nettoie les eventuelles anciennes lignes
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

# Ajoute si absent
grep -qE '^PubkeyAuthentication' "$SSHD" || echo "PubkeyAuthentication yes" >> "$SSHD"
grep -qE '^AuthorizedKeysFile' "$SSHD" || echo "AuthorizedKeysFile .ssh/authorized_keys" >> "$SSHD"
grep -qE '^PermitEmptyPasswords' "$SSHD" || echo "PermitEmptyPasswords no" >> "$SSHD"
grep -qE '^MaxAuthTries' "$SSHD" || echo "MaxAuthTries 3" >> "$SSHD"
grep -qE '^LoginGraceTime' "$SSHD" || echo "LoginGraceTime 20" >> "$SSHD"
grep -qE '^ClientAliveInterval' "$SSHD" || echo "ClientAliveInterval 300" >> "$SSHD"
grep -qE '^ClientAliveCountMax' "$SSHD" || echo "ClientAliveCountMax 2" >> "$SSHD"
grep -qE '^X11Forwarding' "$SSHD" || echo "X11Forwarding no" >> "$SSHD"
grep -qE '^AllowTcpForwarding' "$SSHD" || echo "AllowTcpForwarding no" >> "$SSHD"
grep -qE '^AllowUsers' "$SSHD" || echo "AllowUsers $VPS_USER" >> "$SSHD"

sshd -t
systemctl restart ssh

echo "IMPORTANT: garde cette session ouverte. Ensuite teste: ssh -p $SSH_PORT $VPS_USER@<ip>"