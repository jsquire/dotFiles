#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Must not run as root
############################################

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Run as the target user with sudo access."
    echo "  Usage: ./bootstrap.sh"
    exit 1
fi


############################################
# Version Targets
############################################

NVM_VERSION=0.40.4
YAY_BUILD_DIR="${HOME}/.cache/yay-bootstrap"


############################################
# Helper functions
############################################

service_enable_now() {
    if sudo systemctl is-enabled "$1" &>/dev/null; then
        sudo systemctl is-active "$1" &>/dev/null || sudo systemctl start "$1"
    else
        sudo systemctl enable "$1" --now
    fi
}

group_ensure() {
    getent group "$1" &>/dev/null || sudo groupadd "$1"
}

user_ensure_system() {
    id -u "$1" &>/dev/null || sudo useradd --system --no-create-home --shell /usr/bin/nologin "$1"
}

user_in_group() {
    id -nG "$1" | tr ' ' '\n' | grep -qx "$2"
}


############################################
# System update (safe on CachyOS)
############################################

sudo pacman -Syu --noconfirm


############################################
# Install yay (AUR helper)
############################################

if ! command -v yay &>/dev/null; then
    sudo pacman -S --needed --noconfirm base-devel git
    rm -rf "$YAY_BUILD_DIR"
    mkdir -p "$(dirname "$YAY_BUILD_DIR")"
    git clone https://aur.archlinux.org/yay.git "$YAY_BUILD_DIR"
    (
        cd "$YAY_BUILD_DIR"
        makepkg -si --noconfirm
    )
    rm -rf "$YAY_BUILD_DIR"
fi


############################################
# Base Packages & CLI Tools
############################################

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
    cifs-utils \
    openssh \
    linux-headers \
    dkms \
    pinentry

sudo pacman -S --needed --noconfirm \
    btop \
    bat \
    eza \
    fd \
    ripgrep \
    lazygit \
    github-cli \
    git-lfs \
    tmux


############################################
# Micro editor
############################################

if [ ! -f /usr/local/bin/micro ]; then
    sudo mkdir -p /usr/local/bin
    (
        cd /usr/local/bin
        wget -qO- https://getmic.ro | sudo bash
    )
fi


############################################
# ZSH + Home Configuration
############################################

sudo pacman -S --needed --noconfirm zsh cachyos-zsh-config
[[ "$(getent passwd "$USER" | cut -d: -f7)" == "/usr/bin/zsh" ]] || chsh -s /usr/bin/zsh

cp "${SCRIPT_DIR}/home/.bashrc"    "$HOME/.bashrc"
cp "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"
cp "${SCRIPT_DIR}/home/.gitconfig" "$HOME/.gitconfig"
cp "${SCRIPT_DIR}/home/.gitignore" "$HOME/.gitignore"
cp "${SCRIPT_DIR}/home/.p10k.zsh"  "$HOME/.p10k.zsh"
cp "${SCRIPT_DIR}/home/.profile"   "$HOME/.profile"
cp "${SCRIPT_DIR}/home/.zshrc"     "$HOME/.zshrc"
mkdir -p "$HOME/.gnupg"
cp "${SCRIPT_DIR}/home/.gnupg/gpg-agent.conf" "$HOME/.gnupg/gpg-agent.conf"
chmod 700 "$HOME/.gnupg"
chmod 600 "$HOME/.gnupg/gpg-agent.conf"


############################################
# KDE Plasma Desktop + xrdp
############################################

sudo pacman -S --needed --noconfirm \
    plasma-meta \
    plasma-workspace-x11 \
    sddm \
    xrdp \
    xorgxrdp

service_enable_now sddm
service_enable_now xrdp

if [ -f /etc/xrdp/sesman.ini ]; then
    if grep -Eq '^[[:space:]]*(UserWindowManager|DefaultWindowManager)[[:space:]]*=[[:space:]]*startwm\.sh' /etc/xrdp/sesman.ini; then
        echo "Detected /etc/xrdp/sesman.ini; user sessions will flow through startwm.sh."
    else
        echo "Detected /etc/xrdp/sesman.ini; creating ~/.xsession for Plasma session startup."
    fi
fi

if [ ! -f "$HOME/.xsession" ] || ! grep -qx 'exec startplasma-x11' "$HOME/.xsession"; then
    printf '%s\n' 'exec startplasma-x11' > "$HOME/.xsession"
    chmod 644 "$HOME/.xsession"
fi


############################################
# ZFS
############################################

if ! command -v zfs &>/dev/null; then
    sudo pacman -S --needed --noconfirm zfs-utils zfs-dkms 2>/dev/null || \
        yay -S --needed --noconfirm zfs-dkms zfs-utils
fi

service_enable_now zfs-import-cache
service_enable_now zfs-mount
service_enable_now zfs-share
service_enable_now zfs-zed
sudo bash "${SCRIPT_DIR}/zfs/zfs-properties.sh"


############################################
# Samba
############################################

sudo pacman -S --needed --noconfirm samba

group_ensure share-users
group_ensure virt-admin
user_ensure_system smbguest

user_in_group "$USER" share-users || sudo usermod -aG share-users "$USER"
user_in_group "$USER" virt-admin || sudo usermod -aG virt-admin "$USER"

sudo cp "${SCRIPT_DIR}/samba/smb.conf" /etc/samba/smb.conf
sudo cp "${SCRIPT_DIR}/samba/smbusers" /etc/samba/smbusers

service_enable_now smb

sudo mkdir -p /storage/public /storage/media /storage/media-source /storage/backups
sudo chmod 2775 /storage /storage/media /storage/media-source /storage/backups
sudo chmod 2777 /storage/public

# Only set group ownership on freshly-created directories (not recursively on existing data)
for dir in /storage /storage/media /storage/media-source /storage/backups; do
    [[ "$(stat -c %G "$dir")" == "share-users" ]] || sudo chgrp share-users "$dir"
done

if getent group nogroup &>/dev/null; then
    sudo chown nobody:nogroup /storage/public
else
    sudo chown nobody:nobody /storage/public
fi


############################################
# Docker
############################################

sudo pacman -S --needed --noconfirm \
    docker \
    docker-compose

service_enable_now docker
user_in_group "$USER" docker || sudo usermod -aG docker "$USER"


############################################
# Avahi / mDNS
############################################

sudo pacman -S --needed --noconfirm avahi
service_enable_now avahi-daemon


############################################
# UFW Firewall
############################################

sudo pacman -S --needed --noconfirm ufw

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo ufw allow ssh
sudo ufw allow 53/tcp        # DNS (pihole)
sudo ufw allow 53/udp        # DNS (pihole)
sudo ufw allow 80/tcp        # Pi-hole admin
sudo ufw allow 443/tcp       # Pi-hole admin (HTTPS)
sudo ufw allow 5353/udp      # Avahi / mDNS
sudo ufw allow 32400/tcp     # Plex
sudo ufw allow 445/tcp       # Samba (SMB)
sudo ufw allow 3389/tcp      # xrdp (RDP)

sudo ufw --force enable
service_enable_now ufw


############################################
# Python (uv-managed)
############################################

if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi


############################################
# Node.js (NVM-managed)
############################################

export NVM_DIR="$HOME/.nvm"

if [ ! -d "$NVM_DIR" ]; then
    mkdir -p "$NVM_DIR"
    curl -o- "https://raw.githubusercontent.com/nvm-sh/nvm/v${NVM_VERSION}/install.sh" | bash
fi

[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

if ! nvm which default &>/dev/null; then
    nvm install --lts
    nvm alias default 'lts/*'
fi


############################################
# Kopia Backup
############################################

if ! command -v kopia &>/dev/null; then
    yay -S --needed --noconfirm kopia-bin
fi

echo "Kopia installed. See cachyos/backups/ for repository and scheduling setup."


############################################
# SSH
############################################

service_enable_now sshd


############################################
# Cleanup
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


############################################
# Final message
############################################

echo
echo "CachyOS server bootstrap complete."
echo "Configured: system updates, yay, CLI tools, zsh dotfiles, Plasma + xrdp, ZFS, Samba, Docker, Avahi, UFW, uv, NVM, Kopia, and SSH."
echo "Manual follow-up: run smbpasswd for Samba users, import or create ZFS pools, and finish Kopia setup from cachyos/backups/."
echo "Log out and back in for shell and group membership changes (docker, share-users, virt-admin)."
