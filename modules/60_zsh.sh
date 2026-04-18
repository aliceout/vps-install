#!/usr/bin/env bash
set -euo pipefail

echo "Oh My Zsh + plugins + powerlevel10k (pour $VPS_USER)"
apt-get install -y zsh git

ZHOME="/home/$VPS_USER"
ZSHDIR="$ZHOME/.oh-my-zsh"

# On se place dans un dossier traversable par $VPS_USER (le dossier d'install du
# bootstrap peut etre /home/debian/... donc inaccessible a choupi).
cd "$ZHOME"

if [[ ! -d "$ZSHDIR" ]]; then
  sudo -u "$VPS_USER" env RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    bash -c 'bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"'
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

echo "Deploiement .p10k.zsh"
cp -a "$ROOT_DIR/config/zsh/p10k.zsh" "$ZHOME/.p10k.zsh"
chown "$VPS_USER:$VPS_USER" "$ZHOME/.p10k.zsh"

echo "Shell par defaut -> zsh"
chsh -s /usr/bin/zsh "$VPS_USER"

# Revient dans le dossier d'origine pour les modules suivants
cd "$ROOT_DIR"
