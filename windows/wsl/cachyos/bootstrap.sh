#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Version Targets
############################################

NVM_VERSION=0.40.4


############################################
# wsl.conf
############################################

WSL_CONF="/etc/wsl.conf"
WSL_CONF_CHANGED=false

if ! grep -q "\[automount\]" "$WSL_CONF" 2>/dev/null; then
    echo "Adding [automount] section to wsl.conf..."
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[automount]
enabled=true
options=metadata,uid=1000,gid=1000,umask=022
EOF
    WSL_CONF_CHANGED=true
fi

if ! grep -q "\[boot\]" "$WSL_CONF" 2>/dev/null; then
    echo "Adding [boot] section to wsl.conf..."
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[boot]
systemd = true
EOF
    WSL_CONF_CHANGED=true
fi

if ! grep -q "\[interop\]" "$WSL_CONF" 2>/dev/null; then
    echo "Adding [interop] section to wsl.conf..."
    sudo tee -a "$WSL_CONF" > /dev/null <<'EOF'

[interop]
enabled = true
appendWindowsPath = true
EOF
    WSL_CONF_CHANGED=true
fi


############################################
# Detect Windows username for symlinks
############################################

# Try cmd.exe directly, fall back to /init wrapper (interop may not be
# registered when systemd is enabled until wsl.conf [interop] is set).

WIN_USER=$(cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)

if [ -z "$WIN_USER" ]; then
    WIN_USER=$(/init /mnt/c/Windows/System32/cmd.exe /c "echo %USERNAME%" 2>/dev/null | tr -d '\r' || true)
fi

WIN_HOME="/mnt/c/Users/${WIN_USER}"

if [ -z "$WIN_USER" ] || [ ! -d "$WIN_HOME" ]; then
    if [ "$WSL_CONF_CHANGED" = true ]; then
        echo "ERROR: Could not detect Windows username."
        echo "       wsl.conf was updated. Restart WSL and re-run this script:"
        echo "         wsl --shutdown && wsl -d CachyOS"
    else
        echo "ERROR: Could not detect Windows username or home directory not found at $WIN_HOME"
    fi
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
# Install yay (AUR helper)
############################################

if ! command -v yay &>/dev/null; then
    sudo pacman -S --needed --noconfirm base-devel git
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd "$SCRIPT_DIR"
    rm -rf /tmp/yay
fi


############################################
# Base development & utilities
############################################
#
# NOTE: gnupg, gpgme, ca-certificates, curl,
#       nano, openssl already in CachyOS rootfs.
#       zlib intentionally omitted (CachyOS uses zlib-ng).

sudo pacman -S --needed --noconfirm \
    base-devel \
    git \
    openssh \
    wget \
    net-tools \
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
    ["$HOME/.gnupg"]="${WIN_HOME}/.gnupg"
    ["$HOME/.ssh"]="${WIN_HOME}/.ssh"
    ["$HOME/Desktop"]="${WIN_HOME}/Desktop"
    ["$HOME/Downloads"]="${WIN_HOME}/Downloads"
    ["$HOME/OneDrive"]="${WIN_HOME}/OneDrive"
    ["$HOME/Projects"]="$HOME/src"
)

for link in "${!SYMLINKS[@]}"; do
    target="${SYMLINKS[$link]}"

    if [ -L "$link" ] && [ "$(readlink -f "$link")" = "$(readlink -f "$target")" ]; then
        continue
    fi

    # Remove existing file/directory if it's not already a symlink
    if [ -e "$link" ] && [ ! -L "$link" ]; then
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
    chmod 600 "$HOME/.ssh"/* 2>/dev/null || true
    chmod 640 "$HOME/.ssh"/*.pub 2>/dev/null || true
    [ -f "$HOME/.ssh/known_hosts" ] && chmod 644 "$HOME/.ssh/known_hosts"
fi


############################################
# Shell configuration
############################################

chsh -s /usr/bin/zsh

cp "${SCRIPT_DIR}/home/.bashrc"    "$HOME/.bashrc"
cp "${SCRIPT_DIR}/home/.profile"   "$HOME/.profile"
cp "${SCRIPT_DIR}/home/.zshrc"     "$HOME/.zshrc"
cp "${SCRIPT_DIR}/home/.gitconfig" "$HOME/.gitconfig"
cp "${SCRIPT_DIR}/home/.gitignore" "$HOME/.gitignore"
cp "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"
cp "${SCRIPT_DIR}/home/.p10k.zsh"  "$HOME/.p10k.zsh"

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


###############################################
# Secret Service (secretsd headless keychain)
###############################################

sudo pacman -S --needed --noconfirm \
    libsecret \
    python-cryptography \
    python-dbus \
    python-gobject \
    python-platformdirs \
    python-xdg

if [ ! -d "$HOME/.local/lib/secretsd" ]; then
    git clone https://github.com/grawity/secretsd.git "$HOME/.local/lib/secretsd"
fi

mkdir -p "$HOME/.local/bin" "$HOME/.local/share/nullroute.lt/secretsd"
ln -sf "$HOME/.local/lib/secretsd/secretsd.py" "$HOME/.local/bin/secretsd"
chmod +x "$HOME/.local/bin/secretsd"

mkdir -p "$HOME/.config/systemd/user" "$HOME/.local/share/dbus-1/services"
cp "$HOME/.local/lib/secretsd/systemd/secretsd.service" "$HOME/.config/systemd/user/"
cp "$HOME/.local/lib/secretsd/dbus/org.freedesktop.secrets.service" "$HOME/.local/share/dbus-1/services/"

if [ "$(ps -p 1 -o comm=)" = "systemd" ]; then
    export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

    if [ -S "${XDG_RUNTIME_DIR}/bus" ]; then
        systemctl --user daemon-reload
        systemctl --user enable --now secretsd
    else
        echo "NOTICE: User D-Bus socket not yet available at ${XDG_RUNTIME_DIR}/bus."
        echo "        secretsd will be enabled and start on next login."
        systemctl --user enable secretsd 2>/dev/null || true
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
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
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
    sudo pacman -Rns --noconfirm $ORPHANS
fi

if command -v paccache &>/dev/null; then
    sudo paccache -r
else
    sudo pacman -Sc --noconfirm
fi
