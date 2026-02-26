#!/bin/bash

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Version Targets
############################################

NVM_VERSION=0.40.4
CHRUBY_VERSION=0.3.9
RUBY_INSTALL_VERSION=0.10.2


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

declare -A SYMLINKS=(
    ["$HOME/.aws"]="${WIN_HOME}/.aws"
    ["$HOME/.azure"]="${WIN_HOME}/.azure"
    ["$HOME/.gnupg"]="${WIN_HOME}/.gnupg"
    ["$HOME/.ssh"]="${WIN_HOME}/.ssh"
    ["$HOME/Desktop"]="${WIN_HOME}/Desktop"
    ["$HOME/Downloads"]="${WIN_HOME}/Downloads"
    ["$HOME/OneDrive"]="${WIN_HOME}/OneDrive"
    ["$HOME/Projects"]="/mnt/d"
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

if ! nvm which default &>/dev/null; then
    nvm install --lts
    nvm alias default 'lts/*'
fi

nvm use default

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
rustup component add rustfmt clippy 2>/dev/null || true


############################################
# Install Ruby (Chruby + ruby-install)
############################################

if [ ! -f /usr/local/share/chruby/chruby.sh ]; then
    wget -O /tmp/chruby-${CHRUBY_VERSION}.tar.gz \
        https://github.com/postmodern/chruby/archive/v${CHRUBY_VERSION}.tar.gz
    tar -xzf /tmp/chruby-${CHRUBY_VERSION}.tar.gz -C /tmp
    cd /tmp/chruby-${CHRUBY_VERSION}/
    sudo make install
    cd "$SCRIPT_DIR"
    rm -rf /tmp/chruby-${CHRUBY_VERSION}*
fi

if ! command -v ruby-install &>/dev/null; then
    wget -O /tmp/ruby-install-${RUBY_INSTALL_VERSION}.tar.gz \
        https://github.com/postmodern/ruby-install/archive/v${RUBY_INSTALL_VERSION}.tar.gz
    tar -xzf /tmp/ruby-install-${RUBY_INSTALL_VERSION}.tar.gz -C /tmp
    cd /tmp/ruby-install-${RUBY_INSTALL_VERSION}/
    sudo make install
    cd "$SCRIPT_DIR"
    rm -rf /tmp/ruby-install-${RUBY_INSTALL_VERSION}*
fi


############################################
# Install Python
############################################

sudo pacman -S --needed --noconfirm \
    python \
    python-pip \
    python-virtualenv


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
