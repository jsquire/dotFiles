#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Must not run as root
############################################

usage() {
    cat >&2 <<'USAGE'
Usage: ./bootstrap.sh [--full] [options]

Options:
  --full                     Run the full install (container services + NFS media mount).
  --install-dir PATH         Install location for container services and service data.
                             Default: /srv/squire-server
  --nas-host HOST            UNAS Pro hostname/IP that exports the Plex media pool over NFS.
  --nas-media-export PATH    NFS export path on the NAS for the Plex media (Group 2) pool.
  --nas-media-mount PATH     Local mount point for the NAS media export.
                             Default: /mnt/plex-media
  --nas-backup-export PATH   NFS export path on the NAS for the Kopia backup repo.
  --nas-backup-mount PATH    Local mount point for the NAS backup export.
                             Default: /mnt/nas-backups
USAGE
}

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Run as the target user with sudo access."
    usage
    exit 1
fi


############################################
# Arguments
############################################

FULL_INSTALL=false
INSTALL_DIR="/srv/squire-server"
NAS_HOST=""
NAS_MEDIA_EXPORT=""
NAS_MEDIA_MOUNT="/mnt/plex-media"
NAS_BACKUP_EXPORT=""
NAS_BACKUP_MOUNT="/mnt/nas-backups"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --full) FULL_INSTALL=true; shift ;;
        --install-dir)
            [[ -n "${2:-}" ]] || { echo "--install-dir requires a path" >&2; exit 1; }
            INSTALL_DIR="$2"; shift 2 ;;
        --nas-host)
            [[ -n "${2:-}" ]] || { echo "--nas-host requires a value" >&2; exit 1; }
            NAS_HOST="$2"; shift 2 ;;
        --nas-media-export)
            [[ -n "${2:-}" ]] || { echo "--nas-media-export requires a path" >&2; exit 1; }
            NAS_MEDIA_EXPORT="$2"; shift 2 ;;
        --nas-media-mount)
            [[ -n "${2:-}" ]] || { echo "--nas-media-mount requires a path" >&2; exit 1; }
            NAS_MEDIA_MOUNT="$2"; shift 2 ;;
        --nas-backup-export)
            [[ -n "${2:-}" ]] || { echo "--nas-backup-export requires a path" >&2; exit 1; }
            NAS_BACKUP_EXPORT="$2"; shift 2 ;;
        --nas-backup-mount)
            [[ -n "${2:-}" ]] || { echo "--nas-backup-mount requires a path" >&2; exit 1; }
            NAS_BACKUP_MOUNT="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Strip any trailing slash so path joins stay clean.

INSTALL_DIR="${INSTALL_DIR%/}"
NAS_MEDIA_MOUNT="${NAS_MEDIA_MOUNT%/}"
NAS_BACKUP_MOUNT="${NAS_BACKUP_MOUNT%/}"


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
    nfs-utils \
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
    tmux \
    gparted \
    hardinfo2 \
    plasma-systemmonitor \
    xdg-desktop-portal \
    xdg-desktop-portal-kde \
    kdeplasma-addons

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
# VS Code Editor
############################################

yay -S --needed --noconfirm visual-studio-code-bin

############################################
# ZSH + Home Configuration
############################################

sudo pacman -S --needed --noconfirm zsh cachyos-zsh-config
[[ "$(getent passwd "$USER" | cut -d: -f7)" == "/usr/bin/zsh" ]] || chsh -s /usr/bin/zsh

# Install template home files without clobbering personalization.
# .gitconfig carries your git identity (name/email/signing key) and is NEVER
# overwritten when it already exists; the other dotfiles are refreshed from the
# repo, but any existing copy is backed up to <file>.bak-<timestamp> first.
install_home_file() {
    local src="$1" dest="$2" preserve="${3:-}"
    if [ -f "$dest" ]; then
        if [ "$preserve" = "preserve" ]; then
            echo "Keeping existing $dest (personalized; not overwritten)."
            return 0
        fi
        cmp -s "$src" "$dest" || cp -a "$dest" "${dest}.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cp "$src" "$dest"
}

install_home_file "${SCRIPT_DIR}/home/.bashrc"    "$HOME/.bashrc"
install_home_file "${SCRIPT_DIR}/home/.dircolors" "$HOME/.dircolors"
install_home_file "${SCRIPT_DIR}/home/.gitconfig" "$HOME/.gitconfig" preserve
install_home_file "${SCRIPT_DIR}/home/.gitignore" "$HOME/.gitignore"
install_home_file "${SCRIPT_DIR}/home/.p10k.zsh"  "$HOME/.p10k.zsh"
install_home_file "${SCRIPT_DIR}/home/.profile"   "$HOME/.profile"
install_home_file "${SCRIPT_DIR}/home/.zshrc"     "$HOME/.zshrc"
mkdir -p "$HOME/.gnupg"
cp "${SCRIPT_DIR}/home/.gnupg/gpg-agent.conf" "$HOME/.gnupg/gpg-agent.conf"
chmod 700 "$HOME/.gnupg"
chmod 600 "$HOME/.gnupg/gpg-agent.conf"


############################################
# KDE Plasma Desktop + KRDP (Remote Desktop)
############################################

# Remote access uses KDE's built-in Remote Desktop server (KRDP), not xrdp.
# KRDP shares the live Plasma Wayland session (like Windows RDP), which avoids
# xrdp's separate-X-session handling and the dual-session conflicts that come
# with it. plasma-meta provides the Wayland session that KRDP shares.

sudo pacman -S --needed --noconfirm \
    plasma-meta \
    krdp

# plasma-meta pulls plasma-login-manager (KDE's DM) and enables it as
# display-manager.service, so no separate SDDM enable is needed.

# KRDP enablement is per-user and partly interactive, so it is NOT scripted here:
# System Settings -> Remote Desktop generates the TLS certificate, stores the RDP
# credentials in KWallet, and writes ~/.config/krdpserverrc (Autostart=true).
# After first login to the Plasma (Wayland) session:
#   System Settings -> Remote Desktop -> enable it, set a username/password
#   (or "Use system credentials"), then Apply. KRDP then listens on TCP 3389.
#
# KRDP needs a running Plasma Wayland session to share, so this server should
# auto-login to that session at boot (configured in the login manager). Do NOT
# also install/enable xrdp: it would bind TCP 3389 first and prevent KRDP from
# starting.

# CachyOS ships the arch-update (cachy-update) notifier, which enables a per-user
# tray icon + periodic update-check timer. On a headless, SSH-driven server that
# background nag has no value (updates are applied deliberately via pacman -Syu).
# Disable it globally so new user sessions don't start it. --global avoids needing
# a running user systemd instance during provisioning.
sudo systemctl --global disable arch-update.timer arch-update-tray.service 2>/dev/null || true


############################################
# Service groups
############################################

# virt-admin owns the container-services install tree (see --full below).

group_ensure virt-admin
user_in_group "$USER" virt-admin || sudo usermod -aG virt-admin "$USER"


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
sudo ufw allow 53/tcp        # DNS (AdGuard Home)
sudo ufw allow 53/udp        # DNS (AdGuard Home)
sudo ufw allow 80/tcp        # AdGuard Home admin
sudo ufw allow 443/tcp       # AdGuard Home admin (HTTPS)
sudo ufw allow 5353/udp      # Avahi / mDNS
sudo ufw allow 32400/tcp     # Plex
sudo ufw allow 3389/tcp      # KRDP (KDE Remote Desktop / RDP)

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
# Repo lives on the NAS backups export (NFS, Collaborative/all-squash); the Kopia
# repo is the Squire-Server subdirectory. Sources are LOCAL only (home, /etc, /boot,
# install dir) and never the NAS mounts; enforced with --one-file-system below.

KOPIA_REPO="${NAS_BACKUP_MOUNT}/Squire-Server"
KOPIA_BACKUP_SCRIPT="/usr/local/bin/nightly-backup.sh"
KOPIA_MANIFEST_DIR="$HOME/.local/share/system-backup/manifests"
KOPIA_SCHEDULE="02:00:00"
KOPIA_SOURCES=( "$HOME" "/etc" "/boot" "$INSTALL_DIR" )

# Mount the NAS backups export (NFS) so the Kopia repo is reachable.
# Kopia runs as root; writes are accepted under the NAS all-squash policy
# (mapped to the share's anon owner); no no_root_squash required on the NAS.

if [[ -n "$NAS_HOST" && -n "$NAS_BACKUP_EXPORT" ]]; then
    sudo mkdir -p "$NAS_BACKUP_MOUNT"

    backup_fstab_line="${NAS_HOST}:${NAS_BACKUP_EXPORT}  ${NAS_BACKUP_MOUNT}  nfs  _netdev,x-systemd.automount,noatime,nofail  0  0"

    if ! grep -Eq "[[:space:]]${NAS_BACKUP_MOUNT}[[:space:]]+nfs([[:space:]]|$)" /etc/fstab; then
        printf '%s\n' "$backup_fstab_line" | sudo tee -a /etc/fstab >/dev/null
        sudo systemctl daemon-reload
    fi

    # Trigger the automount so the export is available immediately.
    sudo systemctl start "$(systemd-escape -p --suffix=automount "$NAS_BACKUP_MOUNT")" 2>/dev/null || true

    # Ensure the repo subdirectory exists on the share.
    sudo mkdir -p "$KOPIA_REPO" 2>/dev/null || true
fi

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
        echo "WARNING: Kopia repo path $KOPIA_REPO not available (NAS backups export not mounted)."
        echo "  Pass --nas-host and --nas-backup-export (and ensure the NAS is reachable),"
        echo "  then re-run bootstrap to complete Kopia setup."
    fi
fi

# Configure policies (idempotent — kopia overwrites existing policies)

if sudo kopia repository status &>/dev/null; then
    sudo kopia policy set --global --compression=zstd

    for src in "${KOPIA_SOURCES[@]}"; do
        sudo kopia policy set "$src" \
            --one-file-system=true \
            --keep-daily=7 \
            --keep-weekly=4 \
            --keep-monthly=3
    done

    sudo kopia maintenance set --full-interval=720h
fi

# Create .kopiaignore for home directory (server-appropriate exclusions)

cat > "$HOME/.kopiaignore" << 'KOPIAIGNORE'
.cache/
# LLM models (large, re-downloadable); explicit even though .cache/ already covers HF
.cache/huggingface/
.ollama/
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

echo "Manifests written to \${MANIFEST_DIR}"

# Create snapshots
echo "Creating snapshots..."
kopia snapshot create "\${BACKUP_HOME}"
kopia snapshot create /etc
kopia snapshot create /boot
kopia snapshot create ${INSTALL_DIR}

# Repository maintenance
echo "Running repository maintenance..."
kopia maintenance run || echo "WARNING: Maintenance failed (snapshots were saved successfully)"

echo "\$(date '+%Y-%m-%d %H:%M:%S') ── Nightly backup complete ──"
BACKUPSCRIPT

sudo chmod 755 "$KOPIA_BACKUP_SCRIPT"

# Systemd units for scheduled backup

KOPIA_MOUNT_POINT=$(findmnt -n -o TARGET --target "$KOPIA_REPO" 2>/dev/null | head -n1)
KOPIA_MOUNT_POINT="${KOPIA_MOUNT_POINT:-$NAS_BACKUP_MOUNT}"

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
# Full install: NFS media mount + container services
############################################

if [ "$FULL_INSTALL" = true ]; then

    ############################################
    # NFS mount for Plex media (NAS Group 2 pool)
    ############################################

    if [[ -n "$NAS_HOST" && -n "$NAS_MEDIA_EXPORT" ]]; then
        echo
        echo "=== Full install: configuring NFS media mount ==="

        sudo mkdir -p "$NAS_MEDIA_MOUNT"

        nfs_fstab_line="${NAS_HOST}:${NAS_MEDIA_EXPORT}  ${NAS_MEDIA_MOUNT}  nfs  _netdev,x-systemd.automount,noatime,nofail  0  0"

        if ! grep -Eq "[[:space:]]${NAS_MEDIA_MOUNT}[[:space:]]+nfs([[:space:]]|$)" /etc/fstab; then
            printf '%s\n' "$nfs_fstab_line" | sudo tee -a /etc/fstab >/dev/null
            sudo systemctl daemon-reload
        fi

        # Trigger the automount unit so the export is available immediately.

        sudo systemctl start "$(systemd-escape -p --suffix=automount "$NAS_MEDIA_MOUNT")" 2>/dev/null || true
    else
        echo
        echo "WARNING: --nas-host and/or --nas-media-export not provided."
        echo "  Skipping NFS media mount. Plex media at $NAS_MEDIA_MOUNT will be unavailable"
        echo "  until you add an NFS entry to /etc/fstab and re-run with both flags set."
    fi


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


    ############################################
    # Install directory structure
    ############################################

    sudo mkdir -p "$INSTALL_DIR/container-services"
    sudo mkdir -p "$INSTALL_DIR/adguard/"{work,conf}
    sudo mkdir -p "$INSTALL_DIR/plex"

    sudo chgrp virt-admin "$INSTALL_DIR" "$INSTALL_DIR/container-services" "$INSTALL_DIR/adguard" "$INSTALL_DIR/adguard/work" "$INSTALL_DIR/adguard/conf" "$INSTALL_DIR/plex"
    sudo chmod 2775 "$INSTALL_DIR" "$INSTALL_DIR/container-services" "$INSTALL_DIR/adguard" "$INSTALL_DIR/adguard/work" "$INSTALL_DIR/adguard/conf" "$INSTALL_DIR/plex"


    ############################################################################
    # DNS: free :53 for AdGuard Home + point the host resolver at it
    ############################################################################
    #
    # AdGuard Home binds the host's :53 to serve DNS for the whole LAN and
    # forwards upstream over DoH itself (no sidecar). systemd-resolved's stub
    # listener occupies 127.0.0.53:53, so it is removed here to free the port.
    #
    # NetworkManager auto-uses systemd-resolved when it is installed, so simply
    # disabling the service is NOT enough: NM re-activates it over D-Bus and
    # repoints /etc/resolv.conf back at the stub. We therefore (1) tell NM to
    # manage resolv.conf directly (dns=default), (2) MASK resolved so nothing can
    # restart it, then (3) set the host resolver to AdGuard Home (127.0.0.1) with
    # the LAN router as a fallback (so the host also gets DoH + ad-blocking and
    # never depends solely on the container). Idempotent: safe to re-run.

    sudo install -d /etc/NetworkManager/conf.d
    printf '[main]\ndns=default\n' | sudo tee /etc/NetworkManager/conf.d/dns.conf >/dev/null

    sudo systemctl mask --now systemd-resolved 2>/dev/null || true
    
    # Drop a stale systemd-resolved symlink so NetworkManager can manage resolv.conf.
    
    if [ -L /etc/resolv.conf ]; then
        sudo rm -f /etc/resolv.conf
    fi

    sudo systemctl reload NetworkManager 2>/dev/null || sudo systemctl restart NetworkManager

    LAN_ROUTER="$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')"
    PRIMARY_CON="$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-3-ethernet"{print $1; exit}')"

    if [ -n "$PRIMARY_CON" ]; then
        sudo nmcli connection modify "$PRIMARY_CON" ipv4.ignore-auto-dns yes \
            ipv4.dns "127.0.0.1${LAN_ROUTER:+ $LAN_ROUTER}"
        sudo nmcli connection up "$PRIMARY_CON" >/dev/null 2>&1 || true

        echo "Host DNS set to 127.0.0.1 (AdGuard Home)${LAN_ROUTER:+ with fallback $LAN_ROUTER}; systemd-resolved masked."
    else
        echo "WARNING: no active ethernet NetworkManager connection found; set the host DNS to 127.0.0.1 manually." >&2
    fi


    ############################################
    # Container service deployment
    ############################################

    if compgen -G "${SCRIPT_DIR}/container-services/*" >/dev/null; then
        sudo cp -a "${SCRIPT_DIR}/container-services/." "$INSTALL_DIR/container-services/"
    fi

    sudo find "$INSTALL_DIR/container-services" -maxdepth 1 -type f -name '*.sh' -exec chmod 0755 {} +

    # cp -a above re-applies the source dir's attributes onto container-services,
    # clobbering the earlier chgrp/chmod. Re-assert the intended ownership + setgid.

    sudo chgrp virt-admin "$INSTALL_DIR/container-services"
    sudo chmod 2775 "$INSTALL_DIR/container-services"


    ############################################
    # Container systemd units
    ############################################

    service_unit="[Unit]
Description=Squire Server Container Services
After=docker.service
Requires=docker.service

[Service]
Environment=ADGUARD_BASE=${INSTALL_DIR}/adguard
Environment=PLEX_BASE=${INSTALL_DIR}/plex
Environment=PLEX_MEDIA=${NAS_MEDIA_MOUNT}
Environment=PLEX_TRANSCODE=/mnt/transcode
WorkingDirectory=${INSTALL_DIR}/container-services
ExecStartPre=/usr/bin/docker compose -f ${INSTALL_DIR}/container-services/docker-compose.yml down
ExecStart=${INSTALL_DIR}/container-services/start-services.sh --force-recreate --build --wait
ExecStop=/usr/bin/docker compose -f ${INSTALL_DIR}/container-services/docker-compose.yml down
TimeoutSec=120
KillMode=process

[Install]
WantedBy=multi-user.target
"

    timer_unit='[Unit]
Description=Weekly Container Update

[Timer]
OnCalendar=Sat *-*-* 01:00:00
Persistent=true
Unit=squire-server-containers-update.service

[Install]
WantedBy=timers.target
'

    update_service_unit="[Unit]
Description=Update and restart container services
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
WorkingDirectory=${INSTALL_DIR}/container-services
ExecStart=${INSTALL_DIR}/container-services/restart-update.sh
"

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
    echo "- Run ${INSTALL_DIR}/container-services/start-services.sh manually the first time to generate .env and provide secrets."
    echo "- Ensure the NAS NFS export uid/gid matches the Plex container PUID/PGID so Plex can read media at ${NAS_MEDIA_MOUNT}."

fi


############################################
# Done
############################################

echo
echo "Bootstrap complete."
echo "Manual follow-up: finish Kopia setup from cachyos/backups/ and verify the NFS media mount."
echo "Log out and back in for shell and group membership changes."