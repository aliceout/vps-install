#!/usr/bin/env bash
set -euo pipefail

echo "Oh My Zsh + plugins + powerlevel10k (pour $VPS_USER)"
apt-get install -y zsh git

ZHOME="/home/$VPS_USER"
ZSHDIR="$ZHOME/.oh-my-zsh"

if [[ ! -d "$ZSHDIR" ]]; then
  sudo -u "$VPS_USER" sh -c \
    'RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
     bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
fi

# powerlevel10k + plugins
sudo -u "$VPS_USER" mkdir -p "$ZSHDIR/custom/themes" "$ZSHDIR/custom/plugins"

sudo -u "$VPS_USER" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
  "$ZSHDIR/custom/themes/powerlevel10k" 2>/dev/null || true

sudo -u "$VPS_USER" git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions \
  "$ZSHDIR/custom/plugins/zsh-autosuggestions" 2>/dev/null || true

sudo -u "$VPS_USER" git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git \
  "$ZSHDIR/custom/plugins/zsh-syntax-highlighting" 2>/dev/null || true

sudo -u "$VPS_USER" git clone --depth=1 https://github.com/zsh-users/zsh-completions \
  "$ZSHDIR/custom/plugins/zsh-completions" 2>/dev/null || true

echo "Deploiement .zshrc"
cp -a "$ROOT_DIR/config/zsh/zshrc" "$ZHOME/.zshrc"
chown "$VPS_USER:$VPS_USER" "$ZHOME/.zshrc"

echo "Shell par defaut -> zsh"
chsh -s /usr/bin/zsh "$VPS_USER"