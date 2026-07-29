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

# The template .gitconfig ships placeholders rather than a real identity, and it
# sets commit.gpgsign/tag.gpgsign to true. Left unedited, git does not merely
# record a wrong email: every commit fails outright with "gpg: skipped ... No
# secret key" and exit 128. The preserve guard above means a personalized file is
# never clobbered, so this only ever fires on a genuinely unconfigured copy.

if grep -q 'ADD EMAIL HERE\|ADD KEY HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" 2>/dev/null; then
    echo ""
    echo "  ACTION REQUIRED: $HOME/.gitconfig still has template placeholders."
    echo "  commit.gpgsign is enabled, so git commits will FAIL until these are set:"
    grep -n 'ADD EMAIL HERE\|ADD KEY HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" | sed 's/^/    line /'
    echo ""
    echo "  Set them with, for example:"
    echo "    git config --global user.email 'you@example.com'"
    echo "    git config --global user.signingkey '<your-gpg-key-id>'"
    echo "  Or edit $HOME/.gitconfig directly. To commit without signing instead:"
    echo "    git config --global commit.gpgsign false"
    echo "    git config --global tag.gpgsign false"
    echo ""
fi

