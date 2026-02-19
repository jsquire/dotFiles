#!/bin/bash

set -euo pipefail

WORKDIR=$(pwd)

############################################
# Helper functions
############################################

pkg_installed() {
    pacman -Qi "$1" &>/dev/null
}

service_enable_now() {
    systemctl is-enabled "$1" &>/dev/null || sudo systemctl enable "$1" --now
}

############################################
# System update (safe on CachyOS)
############################################

sudo pacman -Syu --noconfirm

############################################
# Install yay (AUR helper)
############################################

if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git
    cd yay
    makepkg -si --noconfirm
    cd ..
    rm -rf yay
fi

############################################
# Base development & utilities
############################################
# NOTE: zlib intentionally omitted (CachyOS uses zlib-ng)

sudo pacman -S --needed --noconfirm \
    base-devel \
    git \
    ca-certificates \
    curl \
    wget \
    net-tools \
    bison \
    openssl \
    gdbm \
    readline \
    libffi \
    dos2unix \
    nano \
    gnupg \
    gpgme \
    pacman-contrib \
    cifs-utils


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
    github-cli


############################################
# Plasma desktop utilities
############################################

sudo pacman -S --needed --noconfirm \
    tmux \
    gparted \
    hardinfo2 \
    avahi \
    plasma-systemmonitor \
    pinentry \
    xdg-desktop-portal \
    xdg-desktop-portal-kde \
    kdeplasma-addons


############################################
# Avahi (mDNS / Bonjour)
############################################

service_enable_now avahi-daemon


############################################
# Micro editor
############################################

if [ ! -f /usr/local/bin/micro ]; then
    sudo mkdir -p /usr/local/bin
    cd /usr/local/bin
    wget -qO- https://getmic.ro | sudo bash
    cd "$WORKDIR"
fi


############################################
# Browser + Code Editor
############################################

yay -S --needed --noconfirm \
    microsoft-edge-stable-bin \
    visual-studio-code-bin \
    heroic-games-launcher-bin

# Tor Browser requires its signing key imported first
TOR_KEY="EF6E286DDA85EA2A4BA7DE684E2C6E8793298290"

if ! gpg --list-keys "$TOR_KEY" &>/dev/null; then
    gpg --keyserver keys.openpgp.org --recv-keys "$TOR_KEY"
fi

yay -S --needed --noconfirm tor-browser-bin


############################################
# Docker
############################################

sudo pacman -S --needed --noconfirm \
    docker \
    docker-compose

service_enable_now docker

# Add user to docker group (avoids needing sudo for docker commands)
sudo usermod -aG docker "$USER"


############################################
# Remmina (Remote Desktop Client)
############################################

sudo pacman -S --needed --noconfirm \
    remmina \
    freerdp \
    libvncserver


############################################
# Gaming stack (CachyOS optimized)
############################################

sudo pacman -S --needed --noconfirm \
    cachyos-gaming-meta \
    lutris \
    wine \
    winetricks \
    vulkan-tools \
    gamemode \
    lib32-gamemode \
    steam \
    proton-cachyos \
    mangohud \
    gamescope \
    lib32-mesa \
    lib32-vulkan-intel \
    lib32-vulkan-radeon \
    vulkan-icd-loader \
    lib32-vulkan-icd-loader \
    protonup-qt

# GameMode is D-Bus activated on demand (no service enable needed)
# User must be in gamemode group for CPU governor and renice features
sudo usermod -aG gamemode "$USER"


############################################
# Flatpak + Flathub + KDE Portal
############################################

sudo pacman -S --needed --noconfirm flatpak
sudo pacman -S --needed --noconfirm bazaar

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y --or-update flathub com.github.tchx84.Flatseal
flatpak install -y --or-update flathub it.mijorus.gearlever
flatpak install -y --or-update flathub io.kopia.KopiaUI
flatpak install -y --or-update flathub org.kde.okular
flatpak install -y --or-update flathub org.onlyoffice.desktopeditors


############################################
# Firewall (UFW)
############################################

sudo pacman -S --needed --noconfirm ufw

service_enable_now ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow ssh
sudo ufw allow 5353/udp    # Avahi / mDNS

sudo ufw --force enable


############################################
# Final cleanup (safe)
############################################

ORPHANS=$(pacman -Qtdq || true)

if [ -n "$ORPHANS" ]; then
    sudo pacman -Rns --noconfirm $ORPHANS
fi

# Use paccache for cleaner cache management (keeps last 3 versions)
# Falls back to pacman -Sc if paccache not available
if command -v paccache &>/dev/null; then
    sudo paccache -r
else
    sudo rm -f /var/cache/pacman/pkg/download-* 2>/dev/null || true
    sudo pacman -Sc --noconfirm
fi
