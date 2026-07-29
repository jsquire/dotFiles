#!/bin/bash

set -euo pipefail

############################################
# Version Targets
############################################



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

# Installed from the official repo (github-copilot-cli) so it lands in /usr/bin
# and is managed by pacman, rather than the user-local wget installer.
sudo pacman -S --needed --noconfirm github-copilot-cli


############################################
# Install Node Version Manager (NVM)
############################################

# Installed from the official repositories rather than a pinned curl installer,
# so pacman -Syu keeps it current. The package ships /usr/share/nvm/init-nvm.sh,
# which sets NVM_DIR (~/.nvm here, since XDG_CONFIG_HOME is unset) and sources
# nvm plus completions.

sudo pacman -S --needed --noconfirm nvm

# Legacy ~/.nvm installs from the old curl installer leave real files where the
# package expects to place symlinks, so init-nvm.sh silently keeps loading the
# stale copy. Report it once; installed node versions under ~/.nvm/versions are
# unaffected and are reused by the packaged nvm.

if [ -f "$HOME/.nvm/nvm.sh" ] && [ ! -L "$HOME/.nvm/nvm.sh" ]; then
    echo
    echo "NOTE: a legacy curl-installed nvm is present in ~/.nvm and will shadow"
    echo "      the packaged one (/usr/share/nvm). Your installed node versions in"
    echo "      ~/.nvm/versions are NOT affected and will be reused."
    echo "      One-time cleanup, then this notice stops appearing:"
    echo "        rm -rf ~/.nvm/nvm.sh ~/.nvm/nvm-exec ~/.nvm/bash_completion \\"
    echo "               ~/.nvm/.git ~/.nvm/*.md ~/.nvm/Dockerfile ~/.nvm/test"
    echo "      Then open a new shell and confirm with: nvm --version"
    echo
fi

# Source NVM for this session
# shellcheck source=/dev/null
[ -s /usr/share/nvm/init-nvm.sh ] && \. /usr/share/nvm/init-nvm.sh


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
