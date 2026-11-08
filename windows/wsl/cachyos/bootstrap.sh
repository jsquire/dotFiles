#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISTRO_NAME="${WSL_DISTRO_NAME:-cachyos}"

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Run this script as the default WSL user, not as root." >&2
    exit 1
fi

if [ "$(ps -p 1 -o comm=)" != "systemd" ]; then
    echo "ERROR: systemd is required for this WSL environment." >&2
    exit 1
fi

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

if [ ! -S "${XDG_RUNTIME_DIR}/bus" ]; then
    echo "ERROR: User D-Bus is not available at ${XDG_RUNTIME_DIR}/bus." >&2
    echo "       Terminate the distribution from PowerShell, then launch it again:" >&2
    echo "         wsl --terminate ${DISTRO_NAME}" >&2
    exit 1
fi

############################################
# Version Targets
############################################

NVM_VERSION=0.40.4


############################################
# wsl.conf
############################################

WSL_CONF="/etc/wsl.conf"
WSL_CONF_CHANGED=false

if ! grep -q '^\[automount\][[:space:]]*$' "$WSL_CONF" 2>/dev/null; then
    echo "Adding [automount] section to wsl.conf..."
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[automount]
enabled=true
options=metadata,umask=022
EOF
    WSL_CONF_CHANGED=true
elif ! awk '
    /^\[automount\][[:space:]]*$/ { in_automount=1; next }
    /^\[[^]]+\][[:space:]]*$/ { in_automount=0 }
    in_automount && /^[[:space:]]*options[[:space:]]*=/ {
        value=$0
        sub(/^[^=]*=/, "", value)
        gsub(/[[:space:]"]/, "", value)
        count=split(value, options, ",")
        for (item=1; item<=count; item++) {
            if (options[item] == "metadata") {
                found=1
            }
        }
    }
    END { exit found ? 0 : 1 }
' "$WSL_CONF"; then
    echo "ERROR: Existing [automount] options in $WSL_CONF do not enable metadata." >&2
    echo "       Add metadata to the options value, terminate ${DISTRO_NAME}, and rerun." >&2
    exit 1
fi

if ! grep -q '^\[boot\][[:space:]]*$' "$WSL_CONF" 2>/dev/null; then
    echo "Adding [boot] section to wsl.conf..."
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[boot]
systemd = true
EOF
    WSL_CONF_CHANGED=true
fi

if [ "$WSL_CONF_CHANGED" = true ]; then
    echo "WSL configuration was updated."
    echo "Terminate the distribution from PowerShell, then rerun this script:"
    echo "  wsl --terminate ${DISTRO_NAME}"
    exit 0
fi

if ! findmnt -rn --mountpoint /mnt/c -o OPTIONS 2>/dev/null |
     grep -Eq '(^|[;,])metadata([;,]|$)'; then
    echo "ERROR: /mnt/c is not mounted with DrvFS metadata enabled." >&2
    echo "       Terminate the distribution from PowerShell, then rerun this script:" >&2
    echo "         wsl --terminate ${DISTRO_NAME}" >&2
    exit 1
fi

############################################
# Detect Windows username for symlinks
############################################

# Read the actual Windows profile path instead of reconstructing it from the
# account name.

WIN_PROFILE=$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r' || true)

if [ -z "$WIN_PROFILE" ]; then
    WIN_PROFILE=$(
        /init /mnt/c/Windows/System32/cmd.exe /c "echo %USERPROFILE%" 2>/dev/null |
            tr -d '\r' || true
    )
fi

WIN_HOME=$(wslpath -u "$WIN_PROFILE" 2>/dev/null || true)

if [ -z "$WIN_PROFILE" ] || [ -z "$WIN_HOME" ] || [ ! -d "$WIN_HOME" ]; then
    echo "ERROR: Could not resolve Windows profile directory from $WIN_PROFILE"
    exit 1
fi

if [ -L "$HOME/.gnupg" ]; then
    echo "ERROR: $HOME/.gnupg is a symlink." >&2
    echo "       The official instance requires a native GnuPG directory." >&2
    exit 1
fi


############################################
# Ensure optimized CachyOS repositories
############################################

if ! grep -Eq '^\[cachyos-(znver4|v4|v3)\]$' /etc/pacman.conf; then
    echo "Selecting optimized CachyOS repositories..."

    if [ ! -x /usr/lib/wsl/optimize-repos ]; then
        echo "ERROR: /usr/lib/wsl/optimize-repos is unavailable." >&2
        exit 1
    fi

    sudo /usr/lib/wsl/optimize-repos
fi

if ! grep -Eq '^\[cachyos-(znver4|v4|v3)\]$' /etc/pacman.conf; then
    echo "ERROR: No optimized CachyOS repository is active." >&2
    exit 1
fi


############################################
# System update
############################################

sudo pacman -Syu --noconfirm


############################################
# Ensure CachyOS ZSH config
############################################

sudo pacman -S --needed --noconfirm cachyos-zsh-config


############################################
# Install yay
############################################

sudo pacman -S --needed --noconfirm yay


############################################
# Base development & utilities
############################################
#
# zlib is intentionally omitted because CachyOS uses zlib-ng.

sudo pacman -S --needed --noconfirm \
    base-devel \
    git \
    openssh \
    wget \
    net-tools \
    less \
    nano \
    bison \
    openssl \
    gdbm \
    readline \
    libffi \
    libyaml \
    mise \
    dos2unix \
    gnupg \
    gpgme \
    pacman-contrib


############################################
# Modern CLI tools
############################################

sudo pacman -S --needed --noconfirm \
    btop \
    bat \
    eza \
    fd \
    ripgrep \
    lazygit \
    github-cli \
    git-lfs


############################################
# Terminal multiplexer
############################################

sudo pacman -S --needed --noconfirm tmux


############################################
# Micro editor
############################################

if [ ! -f /usr/local/bin/micro ]; then
    sudo mkdir -p /usr/local/bin
    cd /usr/local/bin
    wget -qO- https://getmic.ro | sudo bash
    cd "$SCRIPT_DIR"
fi


############################################
# Home directory symlinks
############################################

mkdir -p "$HOME/src"

declare -A SYMLINKS=(
    ["$HOME/.aws"]="${WIN_HOME}/.aws"
    ["$HOME/.azure"]="${WIN_HOME}/.azure"
    ["$HOME/.ssh"]="${WIN_HOME}/.ssh"
    ["$HOME/Desktop"]="${WIN_HOME}/Desktop"
    ["$HOME/Downloads"]="${WIN_HOME}/Downloads"
    ["$HOME/OneDrive"]="${WIN_HOME}/OneDrive"
    ["$HOME/Projects"]="$HOME/src"
)

for link in "${!SYMLINKS[@]}"; do
    target="${SYMLINKS[$link]}"

    if [ ! -e "$target" ]; then
        echo "NOTICE: Skipping $link because $target does not exist."
        continue
    fi

    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target")" ]; then
        continue
    fi

    # Remove existing file/directory if it's not already a symlink
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        if [ -e "${link}.bak" ] || [ -L "${link}.bak" ]; then
            echo "ERROR: Cannot back up $link because ${link}.bak already exists." >&2
            exit 1
        fi

        echo "Backing up existing $link to ${link}.bak"
        mv "$link" "${link}.bak"
    fi

    ln -sfn "$target" "$link"
    echo "Linked $link -> $target"
done


############################################
# Zed WSL launcher
############################################

ZED_LAUNCHER="${WIN_HOME}/AppData/Local/Programs/Zed/bin/zed"

mkdir -p "$HOME/.local/bin"

if [ -x "$ZED_LAUNCHER" ]; then
    ln -sfn "$ZED_LAUNCHER" "$HOME/.local/bin/zed"
else
    echo "NOTICE: Windows Zed was not found at $ZED_LAUNCHER"
fi


############################################
# SSH permissions
############################################

if [ -d "$HOME/.ssh" ]; then
    chmod 700 "$HOME/.ssh"
    find -L "$HOME/.ssh/" -mindepth 1 -maxdepth 1 -type f \
        ! -name '*.pub' \
        ! -name 'known_hosts*' \
        -exec chmod 600 {} +
    find -L "$HOME/.ssh/" -mindepth 1 -maxdepth 1 -type f \
        \( -name '*.pub' -o -name 'known_hosts*' \) \
        -exec chmod 644 {} +
fi


############################################
# Shell configuration
############################################

if [ "$(getent passwd "$USER" | cut -d: -f7)" != "/usr/bin/zsh" ]; then
    sudo chsh -s /usr/bin/zsh "$USER"
fi

cp "${SCRIPT_DIR}/home/.bashrc"    "$HOME/.bashrc"
cp "${SCRIPT_DIR}/home/.profile"   "$HOME/.profile"
cp "${SCRIPT_DIR}/home/.zshrc"     "$HOME/.zshrc"
cp "${SCRIPT_DIR}/home/.gitconfig" "$HOME/.gitconfig"
cp "${SCRIPT_DIR}/home/.gitignore" "$HOME/.gitignore"
cp "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"
cp "${SCRIPT_DIR}/home/.p10k.zsh"  "$HOME/.p10k.zsh"

install -d -m 700 "$HOME/.gnupg"
install -m 600 \
    "${SCRIPT_DIR}/home/.gnupg/gpg.conf" \
    "${SCRIPT_DIR}/home/.gnupg/gpg-agent.conf" \
    "$HOME/.gnupg/"

mkdir -p "$HOME/.config/zed"
cp "${SCRIPT_DIR}/home/.config/zed/settings.json" "$HOME/.config/zed/settings.json"


############################################
# Install .NET SDK
############################################

sudo pacman -S --needed --noconfirm \
    dotnet-sdk \
    dotnet-runtime \
    aspnet-runtime


############################################
# Install Azure CLI
############################################

sudo pacman -S --needed --noconfirm azure-cli


############################################
# Install GitHub Copilot CLI
############################################

wget -qO- https://gh.io/copilot-install | bash


############################################
# Secret Service (GNOME Keyring)
############################################

sudo pacman -S --needed --noconfirm \
    gnome-keyring \
    libsecret

if systemctl --user is-active --quiet secretsd.service ||
   systemctl --user is-enabled --quiet secretsd.service; then
    systemctl --user disable --now secretsd.service
fi

rm -f \
    "$HOME/.config/systemd/user/secretsd.service" \
    "$HOME/.local/share/dbus-1/services/org.freedesktop.secrets.service"

systemctl --user daemon-reload

KEYRING_ENVIRONMENT=()

for VARIABLE in DISPLAY WAYLAND_DISPLAY XAUTHORITY; do
    if [ -n "${!VARIABLE:-}" ]; then
        KEYRING_ENVIRONMENT+=("$VARIABLE")
    fi
done

if [ "${#KEYRING_ENVIRONMENT[@]}" -gt 0 ]; then
    systemctl --user import-environment "${KEYRING_ENVIRONMENT[@]}"
fi

systemctl --user enable --now gnome-keyring-daemon.socket

if ! busctl --user call \
    org.freedesktop.secrets \
    /org/freedesktop/secrets \
    org.freedesktop.DBus.Peer \
    Ping >/dev/null; then
    echo "ERROR: GNOME Keyring did not provide org.freedesktop.secrets." >&2
    exit 1
fi

rm -f "$HOME/.local/bin/secretsd"
rm -rf "$HOME/.local/lib/secretsd"

SECRETS_DATA="$HOME/.local/share/nullroute.lt/secretsd"

if [ -d "$SECRETS_DATA" ]; then
    if [ -n "$(find "$SECRETS_DATA" -mindepth 1 -print -quit)" ]; then
        echo "NOTICE: Legacy secretsd data was preserved at $SECRETS_DATA."
        echo "        Remove it after confirming that no stored credential is still needed."
    else
        rmdir "$SECRETS_DATA"
    fi
fi


############################################
# Install PowerShell (AUR)
############################################

yay -S --needed --noconfirm powershell-bin


############################################
# Install Node Version Manager (NVM)
############################################

export NVM_DIR="$HOME/.nvm"

if [ ! -d "$NVM_DIR" ]; then
    echo "Installing NVM..."
    mkdir -p "$NVM_DIR"
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" |
        PROFILE=/dev/null bash
else
    echo "NVM already installed at $NVM_DIR"
fi

# Source NVM for this session
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"


############################################
# Install Node + Global Tooling
############################################

# Install (or upgrade to) the latest Node release and make it the
# default. 'node' resolves to the newest available version each run.

nvm install node
nvm alias default node
nvm use node

npm install -g npm

npm install -g \
    typescript \
    @babel/cli \
    @babel/core \
    eslint \
    nyc \
    webpack-cli \
    webpack


############################################
# Install Rust Toolchain
############################################

# rustup conflicts with system rust package

if pacman -Qi rust &>/dev/null; then
    echo "Removing system rust package (conflicts with rustup)..."
    sudo pacman -Rns --noconfirm rust 2>/dev/null || true
fi

sudo pacman -S --needed --noconfirm \
    rustup \
    clang \
    lldb \
    pkg-config \
    openssl

rustup default stable
rustup component add rustfmt clippy rust-analyzer


############################################
# Install Ruby and Go with mise
############################################

mise use --global \
    ruby@latest \
    go@latest

if [[ "$(mise settings get idiomatic_version_file_enable_tools)" != *'"ruby"'* ]]; then
    mise settings add idiomatic_version_file_enable_tools ruby
fi

RUBY_VERSION="$(mise exec -- ruby -e 'print RUBY_VERSION')"
GO_VERSION="$(mise exec -- go env GOVERSION)"

if [ -z "$RUBY_VERSION" ]; then
    echo "ERROR: mise did not activate Ruby"
    exit 1
fi

if [ -z "$GO_VERSION" ]; then
    echo "ERROR: mise did not activate Go"
    exit 1
fi

echo "Using Ruby $RUBY_VERSION"
echo "Using $GO_VERSION"

RUBY_BIN="$(mise exec -- ruby -rrubygems -e 'print Gem.bindir')"
GO_BIN="$(mise exec -- go env GOBIN)"

if [ -z "$GO_BIN" ]; then
    GO_BIN="$(mise exec -- go env GOPATH)/bin"
fi

mkdir -p "$GO_BIN"

mise exec -- gem install --no-document \
    bundler \
    ruby-lsp \
    debug

mise exec -- go install golang.org/x/tools/gopls@latest
mise exec -- go install github.com/go-delve/delve/cmd/dlv@latest
mise exec -- go install honnef.co/go/tools/cmd/staticcheck@latest

for tool in bundle ruby-lsp rdbg; do
    if [ ! -x "${RUBY_BIN}/${tool}" ]; then
        echo "ERROR: Ruby tool was not installed at ${RUBY_BIN}/${tool}"
        exit 1
    fi
done

for tool in gopls dlv staticcheck; do
    if [ ! -x "${GO_BIN}/${tool}" ]; then
        echo "ERROR: Go tool was not installed at ${GO_BIN}/${tool}"
        exit 1
    fi
done


############################################
# Remove legacy Ruby managers
############################################

sudo rm -f \
    /usr/local/bin/chruby-exec \
    /usr/local/bin/ruby-install \
    /usr/local/man/man1/ruby-install.1 \
    /usr/local/share/man/man1/ruby-install.1

sudo rm -rf \
    /usr/local/share/chruby \
    /usr/local/share/ruby-install \
    /usr/local/share/doc/chruby-0.3.9 \
    /usr/local/share/doc/ruby-install-0.10.2

rm -rf "$HOME/.rubies"

if [ -f "$HOME/.ruby-version" ] &&
   [[ "$(<"$HOME/.ruby-version")" == ruby-* ]]; then
    rm -f "$HOME/.ruby-version"
fi

rm -f "$HOME/.local/state/cachyos-development/ruby-install-release"
rmdir "$HOME/.local/state/cachyos-development" 2>/dev/null || true


############################################
# Install Python
############################################

sudo pacman -S --needed --noconfirm \
    python \
    python-pip \
    python-virtualenv \
    uv

# Install the latest uv-managed CPython (version-qualified python3.x in
# ~/.local/bin). The Arch 'python' package above stays as the system
# python/python3; uv uses this managed build for uv-created venvs.

uv python install


############################################
# Additional Dev Tools
############################################

sudo pacman -S --needed --noconfirm \
    jq \
    yq \
    httpie \
    cmake \
    meson \
    ninja


############################################
# Final cleanup
############################################

ORPHANS=$(pacman -Qtdq || true)

if [ -n "$ORPHANS" ]; then
    echo "NOTICE: The following orphaned packages were not removed automatically:"
    printf '  %s\n' $ORPHANS
fi

if command -v paccache &>/dev/null; then
    sudo paccache -r
else
    sudo pacman -Sc --noconfirm
fi
