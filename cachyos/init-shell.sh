#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# ZSH Shell
############################################

sudo pacman -S --needed --noconfirm zsh
chsh -s /usr/bin/zsh

############################################
# Home Configuration
############################################

# Install template home files without clobbering personalization.
# .gitconfig carries your git identity (name/email/signing key) and is NEVER
# overwritten when it already exists; the other dotfiles are refreshed from the
# repo, but any existing copy is backed up to <file>.bak-<timestamp> first.
install_home_file() {
    local src="$1" dest="$2" preserve="${3:-}"
    if [ -f "$dest" ]; then
        if [ "$preserve" = "preserve" ]; then
            echo "Keeping existing $dest (personalized; not overwritten)."
            return 0
        fi
        cmp -s "$src" "$dest" || cp -a "$dest" "${dest}.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cp "$src" "$dest"
}

install_home_file "${SCRIPT_DIR}/home/.bashrc"    "$HOME/.bashrc"
install_home_file "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"
install_home_file "${SCRIPT_DIR}/home/.gitconfig" "$HOME/.gitconfig" preserve
install_home_file "${SCRIPT_DIR}/home/.gitignore" "$HOME/.gitignore"
install_home_file "${SCRIPT_DIR}/home/.p10k.zsh"  "$HOME/.p10k.zsh"
install_home_file "${SCRIPT_DIR}/home/.profile"   "$HOME/.profile"
install_home_file "${SCRIPT_DIR}/home/.zshrc"     "$HOME/.zshrc"

