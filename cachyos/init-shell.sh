#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target desktop user, not as root." >&2
    exit 1
fi

############################################
# ZSH Shell
############################################

sudo pacman -S --needed --noconfirm openssh zsh
chsh -s /usr/bin/zsh

############################################
# Home Configuration
############################################

# Install template home files without clobbering personalization.
# .gitconfig carries your Git identity and signing configuration and is NEVER
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

git config --global user.signingkey '~/.ssh/github_signing.pub'
git config --global gpg.format ssh
git config --global gpg.ssh.allowedSignersFile '~/.ssh/allowed_signers'
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global --unset-all gpg.program 2>/dev/null || true
git config --global --remove-section gpg.openpgp 2>/dev/null || true

mkdir -p "$HOME/.config/ghostty/themes"
install_home_file \
    "${SCRIPT_DIR}/home/.config/ghostty/config.ghostty" \
    "$HOME/.config/ghostty/config.ghostty"
install_home_file \
    "${SCRIPT_DIR}/home/.config/ghostty/themes/Jesse" \
    "$HOME/.config/ghostty/themes/Jesse"

mkdir -p "$HOME/.config/zed"
install_home_file \
    "${SCRIPT_DIR}/home/.config/zed/settings.json" \
    "$HOME/.config/zed/settings.json"

mkdir -p "$HOME/.config/environment.d"
printf 'SSH_AUTH_SOCK=/run/user/%s/ssh-agent.socket\n' "$(id -u)" \
    > "$HOME/.config/environment.d/10-ssh-agent.conf"
export SSH_AUTH_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/ssh-agent.socket"
systemctl --user enable --now ssh-agent.socket

if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    [ ! -f "$HOME/.ssh/github_signing" ] || chmod 600 "$HOME/.ssh/github_signing"
    [ ! -f "$HOME/.ssh/github_signing.pub" ] || chmod 640 "$HOME/.ssh/github_signing.pub"
    [ ! -f "$HOME/.ssh/allowed_signers" ] || chmod 640 "$HOME/.ssh/allowed_signers"
fi

# The template uses a fixed SSH signing-key path and enables commit and tag
# signing. A missing identity file or placeholder email makes every commit fail.

if grep -q 'ADD EMAIL HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" 2>/dev/null; then
    echo ""
    echo "  ACTION REQUIRED: $HOME/.gitconfig still has template placeholders."
    echo "  Automatic SSH signing is enabled, so Git commits will fail until these are set:"
    grep -n 'ADD EMAIL HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" | sed 's/^/    line /'
    echo ""
    echo "  Set them with, for example:"
    echo "    git config --global user.email 'you@example.com'"
    echo "  Or edit $HOME/.gitconfig directly. To commit without signing instead:"
    echo "    git config --global commit.gpgsign false"
    echo "    git config --global tag.gpgsign false"
    echo ""
fi

for required_file in \
    "$HOME/.ssh/github_signing" \
    "$HOME/.ssh/github_signing.pub" \
    "$HOME/.ssh/allowed_signers"; do
    if [ ! -f "$required_file" ]; then
        echo "  ACTION REQUIRED: restore $required_file from the SSH identity backup."
    fi
done

echo
echo "ACTION REQUIRED: run this yourself in your terminal, not through Copilot:"
echo '  SSH_AUTH_SOCK="/run/user/$(id -u)/ssh-agent.socket" ssh-add "$HOME/.ssh/github_signing"'
echo "This explicitly targets the host-local agent instead of an inherited forwarded agent."
