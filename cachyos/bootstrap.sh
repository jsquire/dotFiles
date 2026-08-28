#!/bin/bash

set -euo pipefail

WORKDIR=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLY_PLASMA_CUSTOMIZATION=false
PLASMA_WALLPAPER=""
ENABLE_FIREWALL=false
SSH_PORT=""
RUN_PACKAGE_MAINTENANCE=false

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

Options:
  --plasma-customization       Apply the optional tracked Plasma appearance profile.
  --plasma-wallpaper <path>    Use a personal wallpaper with the Plasma profile.
                               Implies --plasma-customization.
  --enable-firewall            Configure UFW rules and enable the firewall.
  --ssh-port <port>            TCP port to allow for SSH. Required with
                               --enable-firewall.
  --package-maintenance        Remove orphaned dependencies and prune package caches.
  -h, --help                   Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plasma-customization)
            APPLY_PLASMA_CUSTOMIZATION=true
            ;;
        --plasma-wallpaper)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --plasma-wallpaper requires a path." >&2
                exit 2
            }
            APPLY_PLASMA_CUSTOMIZATION=true
            PLASMA_WALLPAPER="$2"
            shift
            ;;
        --enable-firewall)
            ENABLE_FIREWALL=true
            ;;
        --ssh-port)
            [ "$#" -ge 2 ] || {
                echo "ERROR: --ssh-port requires a port number." >&2
                exit 2
            }
            SSH_PORT="$2"
            shift
            ;;
        --package-maintenance)
            RUN_PACKAGE_MAINTENANCE=true
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

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target desktop user, not as root." >&2
    exit 1
fi

if [ -n "$SSH_PORT" ] &&
    { ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; }; then
    echo "ERROR: --ssh-port must be an integer from 1 through 65535." >&2
    exit 2
fi

if [ "$ENABLE_FIREWALL" = true ] && [ -z "$SSH_PORT" ]; then
    echo "ERROR: --enable-firewall requires an explicit --ssh-port." >&2
    exit 2
fi

if [ "$ENABLE_FIREWALL" = false ] && [ -n "$SSH_PORT" ]; then
    echo "ERROR: --ssh-port requires --enable-firewall." >&2
    exit 2
fi

if [ -n "$PLASMA_WALLPAPER" ]; then
    [ -f "$PLASMA_WALLPAPER" ] || {
        echo "ERROR: Plasma wallpaper not found: $PLASMA_WALLPAPER" >&2
        exit 2
    }
    PLASMA_WALLPAPER="$(realpath "$PLASMA_WALLPAPER")"
fi

if [ "$APPLY_PLASMA_CUSTOMIZATION" = true ]; then
    bash "${SCRIPT_DIR}/customize-plasma.sh" --check
fi

############################################
# Helper functions
############################################

service_enable_now() {
    sudo systemctl enable "$1" --now
}

############################################
# System update (safe on CachyOS)
############################################

sudo pacman -Syu --noconfirm

############################################
# Install yay (AUR helper)
############################################

if ! command -v yay &>/dev/null; then
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    cd /tmp/yay
    makepkg -si --noconfirm
    cd "$WORKDIR"
    rm -rf /tmp/yay
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
    github-cli \
    git-lfs


############################################
# Cross-desktop terminal
############################################

sudo pacman -S --needed --noconfirm \
    ghostty \
    ttf-cascadia-mono-nerd


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

# Installed from the official repositories so it is tracked by pacman -Syu.
# The old getmic.ro installer dropped an unmanaged binary in /usr/local/bin,
# which shadows /usr/bin/micro on PATH and therefore never receives updates.

sudo pacman -S --needed --noconfirm micro

if [ -f /usr/local/bin/micro ] && ! pacman -Qo /usr/local/bin/micro &>/dev/null; then
    echo
    echo "NOTE: an unmanaged micro binary is shadowing the packaged one:"
    echo "        /usr/local/bin/micro   (unmanaged, never updated by pacman)"
    echo "        /usr/bin/micro         (packaged, updated by pacman -Syu)"
    echo "      One-time cleanup, then this notice stops appearing:"
    echo "        sudo rm /usr/local/bin/micro"
    echo
fi


############################################
# Browser + Code Editor
############################################

yay -S --needed --noconfirm \
    microsoft-edge-stable-bin \
    visual-studio-code-bin

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
# KRDC (Remote Desktop Client)
############################################

sudo pacman -S --needed --noconfirm \
    krdc \
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

yay -S --needed --noconfirm heroic-games-launcher-bin

# GameMode is D-Bus activated on demand (no service enable needed)
# User must be in gamemode group for CPU governor and renice features

sudo usermod -aG gamemode "$USER"


############################################
# Flatpak + Flathub + KDE Portal
############################################

sudo pacman -S --needed --noconfirm flatpak
sudo pacman -S --needed --noconfirm discover

flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

flatpak install -y --or-update flathub com.github.tchx84.Flatseal
flatpak install -y --or-update flathub it.mijorus.gearlever
flatpak install -y --or-update flathub org.kde.okular
flatpak install -y --or-update flathub org.onlyoffice.desktopeditors


############################################
# Optional firewall (UFW)
############################################

if [ "$ENABLE_FIREWALL" = true ]; then
    sudo pacman -S --needed --noconfirm ufw

    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow "${SSH_PORT}/tcp"
    sudo ufw allow 5353/udp    # Avahi / mDNS

    sudo ufw --force enable
    service_enable_now ufw
fi


############################################
# Optional package maintenance
############################################

if [ "$RUN_PACKAGE_MAINTENANCE" = true ]; then
    ORPHANS=$(pacman -Qtdq || true)

    if [ -n "$ORPHANS" ]; then
        sudo pacman -Rns --noconfirm $ORPHANS
    fi

    if command -v paccache &>/dev/null; then
        sudo paccache -r
    else
        sudo rm -f /var/cache/pacman/pkg/download-* 2>/dev/null || true
        sudo pacman -Sc --noconfirm
    fi
fi

############################################
# Optional Plasma customization
############################################

if [ "$APPLY_PLASMA_CUSTOMIZATION" = true ]; then
    plasma_args=()
    if [ -n "$PLASMA_WALLPAPER" ]; then
        plasma_args+=(--wallpaper "$PLASMA_WALLPAPER")
    fi
    bash "${SCRIPT_DIR}/customize-plasma.sh" "${plasma_args[@]}"
fi