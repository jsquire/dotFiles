#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SHARED_P10K_SOURCE="$REPOSITORY_ROOT/cachyos/home/.p10k.zsh"
SHARED_GHOSTTY_THEME_SOURCE="$REPOSITORY_ROOT/cachyos/home/.config/ghostty/themes/Jesse"
SHARED_ZED_THEME_SOURCE="$REPOSITORY_ROOT/cachyos/home/.config/zed/themes/jesse.json"
GPG_AGENT_CONFIG_SOURCE="$SCRIPT_DIR/home/.gnupg/gpg-agent.conf"
TERMINAL_PROFILE_SOURCE="$SCRIPT_DIR/home/.config/terminal/Jesse.terminal"
SSH_SIGNING_LOADER_SOURCE="$SCRIPT_DIR/home/.config/dotfiles/load-ssh-signing-key.sh"
SSH_SIGNING_LAUNCH_AGENT_SOURCE="$SCRIPT_DIR/home/Library/LaunchAgents/com.jessesquire.github-signing.plist"
STATE_FILE="$HOME/.config/dotfiles/install-state.tsv"
FORCE=false

usage() {
    cat <<'EOF'
Usage: init-shell.sh [options]

Options:
  --force     Replace modified managed configuration files.
  -h, --help  Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

for source_file in \
    "$SHARED_P10K_SOURCE" \
    "$SHARED_GHOSTTY_THEME_SOURCE" \
    "$SHARED_ZED_THEME_SOURCE" \
    "$GPG_AGENT_CONFIG_SOURCE" \
    "$TERMINAL_PROFILE_SOURCE" \
    "$SSH_SIGNING_LOADER_SOURCE" \
    "$SSH_SIGNING_LAUNCH_AGENT_SOURCE"; do
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

file_hash() {
    shasum -a 256 "$1" | awk '{print $1}'
}

read_deployed_hash() {
    local key="$1"

    if [ ! -f "$STATE_FILE" ]; then
        return
    fi

    awk -F '\t' -v key="$key" '
        $1 == key {
            value = $2
        }
        END {
            print value
        }
    ' "$STATE_FILE"
}

write_deployed_hash() {
    local key="$1"
    local hash="$2"
    local state_temp

    state_temp=$(mktemp "$HOME/.config/dotfiles/install-state.XXXXXX")

    if [ -f "$STATE_FILE" ]; then
        awk -F '\t' -v key="$key" '$1 != key' \
            "$STATE_FILE" > "$state_temp"
    fi

    printf '%s\t%s\n' "$key" "$hash" >> "$state_temp"
    mv "$state_temp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

matches_repository_version() {
    local current_hash="$1"
    local src="$2"
    local relative_path
    local commit
    local historical_hash

    if [ ! -d "$REPOSITORY_ROOT/.git" ]; then
        return 1
    fi

    case "$src" in
        "$REPOSITORY_ROOT"/*)
            relative_path="${src#"$REPOSITORY_ROOT"/}"
            ;;
        *)
            return 1
            ;;
    esac

    while IFS= read -r commit; do
        if ! historical_hash=$(
            git -C "$REPOSITORY_ROOT" show "$commit:$relative_path" 2>/dev/null |
                shasum -a 256 |
                awk '{print $1}'
        ); then
            continue
        fi

        if [ "$historical_hash" = "$current_hash" ]; then
            return 0
        fi
    done < <(git -C "$REPOSITORY_ROOT" rev-list --all -- "$relative_path")

    return 1
}

backup_home_file() {
    local dest="$1"
    local backup

    backup=$(mktemp "${dest}.bak-$(date +%Y%m%d%H%M%S).XXXXXX")
    rm -f -- "$backup"
    cp -a "$dest" "$backup"
}

install_home_file() {
    local src="$1"
    local dest="$2"
    local state_key="file:$dest"
    local source_hash
    local current_hash
    local deployed_hash

    source_hash=$(file_hash "$src")

    if [ -e "$dest" ] || [ -L "$dest" ]; then
        current_hash=$(file_hash "$dest" 2>/dev/null || true)

        if [ "$current_hash" = "$source_hash" ]; then
            write_deployed_hash "$state_key" "$source_hash"
            return
        fi

        deployed_hash=$(read_deployed_hash "$state_key")

        if [ -z "$deployed_hash" ] &&
           matches_repository_version "$current_hash" "$src"; then
            deployed_hash="$current_hash"
        fi

        if [ "$FORCE" = false ] &&
           { [ -z "$deployed_hash" ] || [ "$current_hash" != "$deployed_hash" ]; }; then
            echo "Keeping modified $dest. Use --force to replace it."
            return
        fi

        backup_home_file "$dest"

        if [ -L "$dest" ]; then
            rm "$dest"
        fi
    fi

    cp "$src" "$dest"
    write_deployed_hash "$state_key" "$source_hash"
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

install_gpg_agent_config() {
    local pinentry_program
    local rendered_config

    pinentry_program="$(brew --prefix pinentry 2>/dev/null)/bin/pinentry-curses"

    if [ ! -x "$pinentry_program" ]; then
        echo "ERROR: pinentry-curses not found at $pinentry_program" >&2
        exit 1
    fi

    rendered_config=$(mktemp "${TMPDIR:-/tmp}/gpg-agent.XXXXXX")
    sed "s|__PINENTRY_PROGRAM__|$pinentry_program|" \
        "$GPG_AGENT_CONFIG_SOURCE" > "$rendered_config"

    install_home_file \
        "$rendered_config" \
        "$HOME/.gnupg/gpg-agent.conf"
    chmod 600 "$HOME/.gnupg/gpg-agent.conf"
    rm -f -- "$rendered_config"

    gpgconf --kill gpg-agent
}

configure_ssh_signing() {
    local private_key="$HOME/.ssh/github_signing"
    local public_key="$HOME/.ssh/github_signing.pub"
    local allowed_signers="$HOME/.ssh/allowed_signers"
    local missing=false

    for required_file in "$private_key" "$public_key" "$allowed_signers"; do
        if [ ! -f "$required_file" ]; then
            echo "ACTION REQUIRED: restore $required_file from the SSH identity backup."
            missing=true
        fi
    done

    if [ "$missing" = true ]; then
        echo "ERROR: SSH signing identity is incomplete." >&2
        echo "Restore the missing files, then rerun:" >&2
        printf '  bash %q\n' "$SCRIPT_DIR/init-shell.sh" >&2
        return 1
    fi

    chmod 700 "$HOME/.ssh"
    chmod 600 "$private_key"
    chmod 640 "$public_key" "$allowed_signers"
}

terminal_profile_exists() {
    local profile_name="${1:-Jesse}"

    osascript \
        -e "tell application \"Terminal\" to exists settings set \"$profile_name\"" \
        2>/dev/null |
        grep -q true
}

terminal_profile_hash() {
    local mode="$1"
    local path="${2:-}"

    python3 - "$mode" "$path" <<'PY'
import hashlib
import plistlib
import subprocess
import sys

mode = sys.argv[1]
path = sys.argv[2]

if mode == "source":
    with open(path, "rb") as source:
        profile = plistlib.load(source)
else:
    preferences = subprocess.check_output(
        ["defaults", "export", "com.apple.Terminal", "-"]
    )
    profile = plistlib.loads(preferences)["Window Settings"]["Jesse"]

normalized = plistlib.dumps(
    profile,
    fmt=plistlib.FMT_XML,
    sort_keys=True,
)
print(hashlib.sha256(normalized).hexdigest())
PY
}

set_terminal_defaults() {
    osascript <<'APPLESCRIPT'
tell application "Terminal"
    set default settings to settings set "Jesse"
    set startup settings to settings set "Jesse"
end tell
APPLESCRIPT
}

replace_terminal_profile() {
    local attempt
    local import_dir
    local import_name="Jesse Dotfiles Import"
    local import_profile

    import_dir=$(mktemp -d "${TMPDIR:-/tmp}/terminal-profile.XXXXXX")
    import_profile="$import_dir/$import_name.terminal"
    cp "$TERMINAL_PROFILE_SOURCE" "$import_profile"

    osascript \
        -e "tell application \"Terminal\" to if exists settings set \"$import_name\" then delete settings set \"$import_name\""

    open -a Terminal "$import_profile"

    for attempt in {1..20}; do
        terminal_profile_exists "$import_name" && break
        sleep 0.5
    done

    if ! terminal_profile_exists "$import_name"; then
        rm -rf -- "$import_dir"
        echo "ERROR: Terminal did not import the Jesse profile." >&2
        exit 1
    fi

    osascript <<APPLESCRIPT
tell application "Terminal"
    set importedSettings to settings set "$import_name"
    set default settings to importedSettings
    set startup settings to importedSettings

    if exists settings set "Jesse" then
        delete settings set "Jesse"
    end if

    set name of importedSettings to "Jesse"
    set default settings to settings set "Jesse"
    set startup settings to settings set "Jesse"
end tell
APPLESCRIPT

    rm -rf -- "$import_dir"
}

install_terminal_profile() {
    local state_key="terminal:Jesse"
    local source_hash
    local current_hash
    local deployed_hash

    source_hash=$(terminal_profile_hash source "$TERMINAL_PROFILE_SOURCE")
    current_hash=$(terminal_profile_hash current 2>/dev/null || true)

    if [ "$current_hash" = "$source_hash" ]; then
        write_deployed_hash "$state_key" "$source_hash"
        set_terminal_defaults
        return
    fi

    deployed_hash=$(read_deployed_hash "$state_key")

    if [ -n "$current_hash" ] &&
       [ "$FORCE" = false ] &&
       { [ -z "$deployed_hash" ] || [ "$current_hash" != "$deployed_hash" ]; }; then
        echo "Keeping modified Terminal profile Jesse. Use --force to replace it."
        set_terminal_defaults
        return
    fi

    replace_terminal_profile
    current_hash=$(terminal_profile_hash current 2>/dev/null || true)

    if [ "$current_hash" != "$source_hash" ]; then
        echo "ERROR: Terminal profile Jesse does not match the tracked profile." >&2
        exit 1
    fi

    write_deployed_hash "$state_key" "$source_hash"
}

if [ ! -d "$HOME/.oh-my-zsh" ]; then
    git clone --depth=1 \
        https://github.com/ohmyzsh/ohmyzsh.git \
        "$HOME/.oh-my-zsh"
fi

mkdir -p \
    "$HOME/.config/dotfiles" \
    "$HOME/.config/ghostty/themes" \
    "$HOME/.config/zed/themes" \
    "$HOME/Library/LaunchAgents"
install -d -m 700 "$HOME/.gnupg"

install_home_file \
    "$SCRIPT_DIR/home/.config/dotfiles/profile.zsh" \
    "$HOME/.config/dotfiles/profile.zsh"
install_home_file \
    "$SSH_SIGNING_LOADER_SOURCE" \
    "$HOME/.config/dotfiles/load-ssh-signing-key.sh"
chmod 700 "$HOME/.config/dotfiles/load-ssh-signing-key.sh"
install_home_file \
    "$SSH_SIGNING_LAUNCH_AGENT_SOURCE" \
    "$HOME/Library/LaunchAgents/com.jessesquire.github-signing.plist"
chmod 644 "$HOME/Library/LaunchAgents/com.jessesquire.github-signing.plist"
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
    "$HOME/.gitconfig"
git config --global user.signingkey '~/.ssh/github_signing.pub'
git config --global gpg.format ssh
git config --global gpg.ssh.allowedSignersFile '~/.ssh/allowed_signers'
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global --unset-all gpg.program 2>/dev/null || true
git config --global --remove-section gpg.openpgp 2>/dev/null || true
configure_ssh_signing
install_gpg_agent_config
install_terminal_profile

ensure_source_line \
    "$HOME/.zprofile" \
    '[[ -r "$HOME/.config/dotfiles/profile.zsh" ]] && source "$HOME/.config/dotfiles/profile.zsh"'
ensure_source_line \
    "$HOME/.zshrc" \
    '[[ -r "$HOME/.config/dotfiles/shell.zsh" ]] && source "$HOME/.config/dotfiles/shell.zsh"'

if [ "$SHELL" != "/bin/zsh" ]; then
    chsh -s /bin/zsh
fi

if grep -q 'ADD EMAIL HERE\|ADD TOKEN HERE' "$HOME/.gitconfig" 2>/dev/null; then
    echo
    echo "ACTION REQUIRED: $HOME/.gitconfig contains template placeholders."
    echo "Set user.email and any required token before creating signed commits."
fi

echo
echo "Shell and editor configuration installation completed."
echo "In Ghostty 1.3 or later, select Ghostty > Set Ghostty as Default Terminal App."

if [ "${DOTFILES_DEFER_SSH_ACTION:-false}" != "true" ]; then
    echo
    echo "ACTION REQUIRED: run this yourself in a normal local Terminal, not through Copilot or SSH:"
    printf '  SSH_AUTH_SOCK="$(/bin/launchctl getenv SSH_AUTH_SOCK)" /usr/bin/ssh-add --apple-use-keychain %q\n' \
        "$HOME/.ssh/github_signing"
    echo "Then log out and back in once to activate automatic local login loading."
fi
