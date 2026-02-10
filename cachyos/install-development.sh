#!/bin/bash

set -euo pipefail

############################################
# Version Targets
############################################

NVM_VERSION=0.40.4


############################################
# System Update
############################################

sudo pacman -Syu --noconfirm


############################################
# Install .NET SDK (CachyOS / Arch Repo)
############################################

sudo pacman -S --needed --noconfirm \
    dotnet-sdk \
    dotnet-runtime \
    aspnet-runtime

# Verify install
dotnet --version
dotnet --list-sdks


############################################
# Install Azure CLI
############################################

sudo pacman -S --needed --noconfirm azure-cli


############################################
# Install GitHub Copilot CLI
############################################

wget -qO- https://gh.io/copilot-install | bash


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

# Install latest Node LTS if no default set
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
# Install Zed Editor (AUR)
############################################

if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

yay -S --needed --noconfirm zed-preview-bin


############################################
# Install Rust Toolchain
############################################

# rustup conflicts with system rust package - remove it first if present
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

# Install and set stable toolchain as default
# rustup default is idempotent - safe to run multiple times
rustup default stable
rustup component add rustfmt clippy 2>/dev/null || true

# Verify
rustc --version
cargo --version


############################################
# Additional Dev Tools
############################################

sudo pacman -S --needed --noconfirm \
    python \
    python-pip \
    python-virtualenv \
    jq \
    yq \
    httpie \
    cmake \
    meson \
    ninja


############################################
# Environment Setup For Dev Tools (.zshrc)
############################################

ZSHRC="$HOME/.zshrc"
MARKER="### INSTALL-DEVELOPMENT.SH ###"

if ! grep -q "$MARKER" "$ZSHRC" 2>/dev/null; then
    echo "Adding development environment to .zshrc..."
    cat << EOF >> "$ZSHRC"

$MARKER
# NVM
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && source "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && source "\$NVM_DIR/bash_completion"

# Dotnet
export DOTNET_CLI_TELEMETRY_OPTOUT=1
export DOTNET_NOLOGO=1

# Rust Cargo Path
export PATH="\$HOME/.cargo/bin:\$PATH"
$MARKER
EOF
else
    echo "Development environment already in .zshrc"
fi


############################################
# Final System Cleanup
############################################

ORPHANS=$(pacman -Qtdq || true)

if [ -n "$ORPHANS" ]; then
    sudo pacman -Rns --noconfirm $ORPHANS
fi

# Use paccache if available
if command -v paccache &>/dev/null; then
    sudo paccache -r
else
    sudo pacman -Sc --noconfirm
fi
