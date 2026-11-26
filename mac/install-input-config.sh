#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE_DIR="$HOME/.config/dotfiles"
STATE_FILE="$STATE_DIR/input-install-state.tsv"
FORCE=false

if [ "${1:-}" = "--force" ] && [ "$#" -eq 1 ]; then
    FORCE=true
elif [ "$#" -ne 0 ]; then
    echo "Usage: install-input-config.sh [--force]" >&2
    exit 2
fi

mkdir -p "$STATE_DIR"

install_config() {
    local src="$1"
    local dest="$2"
    local source_hash current_hash deployed_hash state_temp backup

    source_hash=$(shasum -a 256 "$src" | awk '{print $1}')
    mkdir -p "$(dirname "$dest")"

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        current_hash=$(shasum -a 256 "$dest" 2>/dev/null | awk '{print $1}' || true)
        if [ "$current_hash" != "$source_hash" ]; then
            deployed_hash=""
            if [ -f "$STATE_FILE" ]; then
                deployed_hash=$(awk -F '\t' -v key="$dest" '$1 == key { value = $2 } END { print value }' "$STATE_FILE")
            fi
            if [ "$FORCE" = false ] &&
               { [ -z "$deployed_hash" ] || [ "$current_hash" != "$deployed_hash" ]; }; then
                echo "Keeping modified $dest. Use --force to replace it."
                return
            fi
            backup=$(mktemp "${dest}.bak-$(date +%Y%m%d%H%M%S).XXXXXX")
            rm -f -- "$backup"
            cp -a "$dest" "$backup"
            if [ -L "$dest" ]; then
                rm "$dest"
            fi
            cp "$src" "$dest"
        fi
    else
        cp "$src" "$dest"
    fi

    state_temp=$(mktemp "$STATE_DIR/input-install-state.XXXXXX")
    if [ -f "$STATE_FILE" ]; then
        awk -F '\t' -v key="$dest" '$1 != key' "$STATE_FILE" > "$state_temp"
    fi
    printf '%s\t%s\n' "$dest" "$source_hash" >> "$state_temp"
    mv "$state_temp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

install_config \
    "$SCRIPT_DIR/home/.config/karabiner/assets/complex_modifications/windows-shortcuts-custom.json" \
    "$HOME/.config/karabiner/assets/complex_modifications/windows-shortcuts-custom.json"

linear_config="$HOME/.config/linearmouse/linearmouse.json"
if [ -e "$HOME/Library/Application Support/linearmouse/linearmouse.json" ] ||
   [ -L "$HOME/Library/Application Support/linearmouse/linearmouse.json" ]; then
    linear_config="$HOME/Library/Application Support/linearmouse/linearmouse.json"
fi

install_config \
    "$SCRIPT_DIR/home/.config/linearmouse/linearmouse.json" \
    "$linear_config"
