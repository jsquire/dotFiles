#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Must not run as root
############################################

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Run as the target user with sudo access."
    echo "  Usage: ./bootstrap.sh [--full]"
    exit 1
fi


############################################
# Arguments
############################################

FULL_INSTALL=false

for arg in "$@"; do
    case "$arg" in
        --full) FULL_INSTALL=true ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: ./bootstrap.sh [--full]" >&2
            exit 1
            ;;
    esac
done


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

install_file_if_changed() {
    local target_path="$1"
    local content="$2"

    if ! sudo test -f "$target_path" || ! diff -q <(printf '%s' "$content") <(sudo cat "$target_path") &>/dev/null; then
        printf '%s' "$content" | sudo tee "$target_path" >/dev/null
        return 0
    fi

    return 1
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

# Non-interactive server backup configuration.
# Repo lives on the external-backups drive; sources are home, /etc, /boot, /virtualization.

KOPIA_REPO="/mnt/external-backups"
KOPIA_BACKUP_SCRIPT="/usr/local/bin/nightly-backup.sh"
KOPIA_MANIFEST_DIR="$HOME/.local/share/system-backup/manifests"
KOPIA_SCHEDULE="02:00:00"
KOPIA_SOURCES=( "$HOME" "/etc" "/boot" "/virtualization" )

# Connect to repository if not already connected
if sudo test -f /root/.config/kopia/repository.config; then
    echo "Kopia repository already connected."
else
    if [ -d "$KOPIA_REPO" ]; then
        # Create the repository if it doesn't exist, otherwise connect
        if sudo kopia repository connect filesystem --path="$KOPIA_REPO" 2>/dev/null; then
            echo "Connected to existing Kopia repository at $KOPIA_REPO"
        else
            sudo kopia repository create filesystem --path="$KOPIA_REPO"
            echo "Created new Kopia repository at $KOPIA_REPO"
        fi
    else
        echo "WARNING: Kopia repo path $KOPIA_REPO not mounted. Skipping repository setup."
        echo "  Mount the external drive and re-run bootstrap to complete Kopia setup."
    fi
fi

# Configure policies (idempotent — kopia overwrites existing policies)
if sudo kopia repository status &>/dev/null; then
    sudo kopia policy set --global --compression=zstd

    for src in "${KOPIA_SOURCES[@]}"; do
        sudo kopia policy set "$src" \
            --keep-daily=7 \
            --keep-weekly=4 \
            --keep-monthly=3
    done

    sudo kopia maintenance set --full-interval=720h
fi

# Create .kopiaignore for home directory (server-appropriate exclusions)
cat > "$HOME/.kopiaignore" << 'KOPIAIGNORE'
.cache/
.var/app/*/cache/
.vscode/extensions/
.config/Code/Cache/
.config/Code/CachedData/
.config/Code/CachedExtensionVSIXs/
.config/Code/CachedProfilesData/
.config/Code/CachedConfigurations/
.rustup/
.nvm/versions/
.npm/
.cargo/registry/
.cargo/git/
.copilot/
.local/share/Trash/
KOPIAIGNORE

# Create manifest staging directory
mkdir -p "$KOPIA_MANIFEST_DIR"

# Create nightly backup script
sudo tee "$KOPIA_BACKUP_SCRIPT" > /dev/null << BACKUPSCRIPT
#!/bin/bash
set -euo pipefail

export HOME=/root

BACKUP_HOME="$HOME"
MANIFEST_DIR="$KOPIA_MANIFEST_DIR"
REPO_PATH="$KOPIA_REPO"

echo "\$(date '+%Y-%m-%d %H:%M:%S') ── Nightly backup started ──"

# Ensure repository is connected
if ! kopia repository status &>/dev/null; then
    echo "Repository not connected. Reconnecting to \${REPO_PATH}..."
    kopia repository connect filesystem --path="\${REPO_PATH}"
fi

# Capture system manifests
echo "Capturing system manifests..."
mkdir -p "\${MANIFEST_DIR}"

pacman -Qe --quiet > "\${MANIFEST_DIR}/pkglist-explicit.txt.tmp" \\
    && mv "\${MANIFEST_DIR}/pkglist-explicit.txt.tmp" "\${MANIFEST_DIR}/pkglist-explicit.txt" \\
    || echo "WARNING: Failed to capture explicit package list"

pacman -Qm --quiet > "\${MANIFEST_DIR}/pkglist-aur.txt.tmp" \\
    && mv "\${MANIFEST_DIR}/pkglist-aur.txt.tmp" "\${MANIFEST_DIR}/pkglist-aur.txt" \\
    || echo "WARNING: Failed to capture AUR package list"

systemctl list-unit-files --state=enabled --no-pager > "\${MANIFEST_DIR}/enabled-services.txt.tmp" \\
    && mv "\${MANIFEST_DIR}/enabled-services.txt.tmp" "\${MANIFEST_DIR}/enabled-services.txt" \\
    || echo "WARNING: Failed to capture enabled services"

cp /etc/fstab "\${MANIFEST_DIR}/fstab.txt" || echo "WARNING: Failed to copy fstab"

zpool status > "\${MANIFEST_DIR}/zpool-status.txt.tmp" \\
    && mv "\${MANIFEST_DIR}/zpool-status.txt.tmp" "\${MANIFEST_DIR}/zpool-status.txt" \\
    || echo "WARNING: Failed to capture zpool status"

zfs list -o name,mountpoint,compression,atime > "\${MANIFEST_DIR}/zfs-datasets.txt.tmp" \\
    && mv "\${MANIFEST_DIR}/zfs-datasets.txt.tmp" "\${MANIFEST_DIR}/zfs-datasets.txt" \\
    || echo "WARNING: Failed to capture ZFS dataset list"

echo "Manifests written to \${MANIFEST_DIR}"

# Create snapshots
echo "Creating snapshots..."
kopia snapshot create "\${BACKUP_HOME}"
kopia snapshot create /etc
kopia snapshot create /boot
kopia snapshot create /virtualization

# Repository maintenance
echo "Running repository maintenance..."
kopia maintenance run || echo "WARNING: Maintenance failed (snapshots were saved successfully)"

echo "\$(date '+%Y-%m-%d %H:%M:%S') ── Nightly backup complete ──"
BACKUPSCRIPT

sudo chmod 755 "$KOPIA_BACKUP_SCRIPT"

# Systemd units for scheduled backup
KOPIA_MOUNT_POINT=$(findmnt -n -o TARGET --target "$KOPIA_REPO" 2>/dev/null || echo "/mnt/external-backups")

backup_service="[Unit]
Description=Nightly Kopia Backup
Wants=network-online.target
After=network-online.target
ConditionPathIsMountPoint=${KOPIA_MOUNT_POINT}

[Service]
Type=oneshot
ExecStart=${KOPIA_BACKUP_SCRIPT}
TimeoutStartSec=10800
StandardOutput=append:/var/log/nightly-backup.log
StandardError=append:/var/log/nightly-backup.log
"

backup_timer="[Unit]
Description=Nightly Kopia Backup Timer

[Timer]
OnCalendar=*-*-* ${KOPIA_SCHEDULE}
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
"

daemon_reload_needed=0

if install_file_if_changed /etc/systemd/system/nightly-backup.service "$backup_service"; then
    daemon_reload_needed=1
fi

if install_file_if_changed /etc/systemd/system/nightly-backup.timer "$backup_timer"; then
    daemon_reload_needed=1
fi

if [ "$daemon_reload_needed" -eq 1 ]; then
    sudo systemctl daemon-reload
fi

service_enable_now nightly-backup.timer

# Log rotation
sudo tee /etc/logrotate.d/nightly-backup > /dev/null << 'LOGROTATE'
/var/log/nightly-backup.log {
    size 5M
    rotate 1
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE


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
# Full install: ZFS pools + container services
############################################

if [ "$FULL_INSTALL" = true ]; then

    echo
    echo "=== Full install: recovering ZFS pools ==="
    sudo bash "${SCRIPT_DIR}/zfs/recover-pools.sh"


    ############################################
    # Ramdisk for Plex transcoding
    ############################################

    if ! grep -Eq '^[^#].*[[:space:]]/mnt/transcode[[:space:]]+tmpfs([[:space:]]|$)' /etc/fstab; then
        printf '%s\n' 'tmpfs  /mnt/transcode  tmpfs  rw,size=4096M  0   0' | sudo tee -a /etc/fstab >/dev/null
    fi

    sudo mkdir -p /mnt/transcode

    if ! mountpoint -q /mnt/transcode; then
        sudo mount /mnt/transcode
    fi


    ############################################
    # Plex user / group mapping
    ############################################

    if ! id -u plex &>/dev/null; then
        sudo useradd --system --create-home --shell /usr/bin/nologin plex
    fi

    sudo usermod -aG share-users plex


    ############################################
    # Virtualization directory structure
    ############################################

    sudo mkdir -p /virtualization/container-services
    sudo mkdir -p /virtualization/pihole/{root,log}
    sudo mkdir -p /virtualization/plex

    sudo chgrp virt-admin /virtualization /virtualization/container-services /virtualization/pihole /virtualization/pihole/root /virtualization/pihole/log /virtualization/plex
    sudo chmod 2775 /virtualization /virtualization/container-services /virtualization/pihole /virtualization/pihole/root /virtualization/pihole/log /virtualization/plex

    sudo touch /virtualization/pihole/log/pihole.log
    sudo chmod 0664 /virtualization/pihole/log/pihole.log


    ############################################
    # Container service deployment
    ############################################

    if compgen -G "${SCRIPT_DIR}/container-services/*" >/dev/null; then
        sudo cp -a "${SCRIPT_DIR}/container-services/." /virtualization/container-services/
    fi

    sudo find /virtualization/container-services -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} +


    ############################################
    # Container systemd units
    ############################################

    service_unit='[Unit]
Description=Squire Server Container Services
After=docker.service
Requires=docker.service

[Service]
WorkingDirectory=/virtualization/container-services
ExecStartPre=/usr/bin/docker compose -f /virtualization/container-services/docker-compose.yml down
ExecStart=/virtualization/container-services/start-services.sh --force-recreate --build --wait
ExecStop=/usr/bin/docker compose -f /virtualization/container-services/docker-compose.yml down
TimeoutSec=120
KillMode=process

[Install]
WantedBy=multi-user.target
'

    timer_unit='[Unit]
Description=Weekly Container Update

[Timer]
OnCalendar=Sat *-*-* 01:00:00
Persistent=true
Unit=squire-server-containers-update.service

[Install]
WantedBy=timers.target
'

    update_service_unit='[Unit]
Description=Update and restart container services
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=/virtualization/container-services
ExecStart=/virtualization/container-services/restart-update.sh
'

    daemon_reload_needed=0

    if install_file_if_changed /etc/systemd/system/squire-server-containers.service "$service_unit"; then
        daemon_reload_needed=1
    fi

    if install_file_if_changed /etc/systemd/system/squire-server-containers-update.timer "$timer_unit"; then
        daemon_reload_needed=1
    fi

    if install_file_if_changed /etc/systemd/system/squire-server-containers-update.service "$update_service_unit"; then
        daemon_reload_needed=1
    fi

    if [ "$daemon_reload_needed" -eq 1 ]; then
        sudo systemctl daemon-reload
    fi

    if ! systemctl is-enabled squire-server-containers.service &>/dev/null; then
        sudo systemctl enable squire-server-containers.service
    fi

    service_enable_now squire-server-containers-update.timer

    echo
    echo 'Full install complete.'
    echo '- Run /virtualization/container-services/start-services.sh manually the first time to generate .env and provide secrets.'
    echo '- Run smbpasswd -a plex if the plex account needs Samba access.'

fi


############################################
# Done
############################################

echo
echo "Bootstrap complete."
echo "Manual follow-up: run smbpasswd for Samba users and finish Kopia setup from cachyos/backups/."
echo "Log out and back in for shell and group membership changes."
