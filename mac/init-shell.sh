#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SHARED_P10K_SOURCE="$REPOSITORY_ROOT/cachyos/home/.p10k.zsh"
SHARED_GHOSTTY_THEME_SOURCE="$REPOSITORY_ROOT/cachyos/home/.config/ghostty/themes/Jesse"
SHARED_ZED_THEME_SOURCE="$REPOSITORY_ROOT/cachyos/home/.config/zed/themes/jesse.json"

for source_file in \
    "$SHARED_P10K_SOURCE" \
    "$SHARED_GHOSTTY_THEME_SOURCE" \
    "$SHARED_ZED_THEME_SOURCE"; do
    if [ ! -f "$source_file" ]; then
        echo "ERROR: shared configuration not found at $source_file" >&2
        echo "Run this script from a complete dotFiles repository clone." >&2
        exit 1
    fi
done

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this installer supports macOS only." >&2
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target user, not as root." >&2
    exit 1
fi

install_home_file() {
    local src="$1"
    local dest="$2"
    local preserve="${3:-}"

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        if [ "$preserve" = "preserve" ]; then
            echo "Keeping existing $dest."
            return
        fi

        cmp -s "$src" "$dest" ||
            cp -a "$dest" "${dest}.bak-$(date +%Y%m%d%H%M%S)"

        if [ -L "$dest" ]; then
            rm "$dest"
        fi
    fi

    cp "$src" "$dest"
}

ensure_source_line() {
    local target="$1"
    local line="$2"

    touch "$target"

    if grep -Fqx "$line" "$target"; then
        return
    fi

    cp -a "$target" "${target}.bak-$(date +%Y%m%d%H%M%S)"
    printf '\n%s\n' "$line" >> "$target"
}

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    git clone --depth=1 \
        https://github.com/ohmyzsh/ohmyzsh.git \
        "$HOME/.oh-my-zsh"
fi

mkdir -p \
    "$HOME/.config/dotfiles" \
    "$HOME/.config/ghostty/themes" \
    "$HOME/.config/zed/themes"

install_home_file \
    "$SCRIPT_DIR/home/.config/dotfiles/profile.zsh" \
    "$HOME/.config/dotfiles/profile.zsh"
install_home_file \
    "$SCRIPT_DIR/home/.config/dotfiles/shell.zsh" \
    "$HOME/.config/dotfiles/shell.zsh"
install_home_file \
    "$SCRIPT_DIR/home/.config/ghostty/config.ghostty" \
    "$HOME/.config/ghostty/config.ghostty"
install_home_file \
    "$SHARED_GHOSTTY_THEME_SOURCE" \
    "$HOME/.config/ghostty/themes/Jesse"
install_home_file \
    "$SCRIPT_DIR/home/.config/zed/settings.json" \
    "$HOME/.config/zed/settings.json"
install_home_file \
    "$SHARED_ZED_THEME_SOURCE" \
    "$HOME/.config/zed/themes/jesse.json"
install_home_file \
    "$SHARED_P10K_SOURCE" \
    "$HOME/.p10k.zsh"
install_home_file \
    "$SCRIPT_DIR/home/.gitignore" \
    "$HOME/.gitignore"
install_home_file \
    "$SCRIPT_DIR/home/.gitconfig" \
    "$HOME/.gitconfig" \
    preserve

ensure_source_line \
    "$HOME/.zprofile" \
    '[[ -r "$HOME/.config/dotfiles/profile.zsh" ]] && source "$HOME/.config/dotfiles/profile.zsh"'
ensure_source_line \
    "$HOME/.zshrc" \
    '[[ -r "$HOME/.config/dotfiles/shell.zsh" ]] && source "$HOME/.config/dotfiles/shell.zsh"'

if [ "$SHELL" != "/bin/zsh" ]; then
    chsh -s /bin/zsh
fi

if grep -q 'ADD EMAIL HERE\|ADD KEY HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" 2>/dev/null; then
    echo
    echo "ACTION REQUIRED: $HOME/.gitconfig contains template placeholders."
    echo "Set user.email and user.signingkey before creating signed commits."
fi

echo
echo "Shell and editor configuration installation completed."
echo "In Ghostty 1.3 or later, select Ghostty > Set Ghostty as Default Terminal App."
