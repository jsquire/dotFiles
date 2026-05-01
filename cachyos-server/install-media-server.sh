#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

############################################
# Helper functions
############################################

service_enable_now() {
    systemctl is-enabled "$1" &>/dev/null || sudo systemctl enable "$1" --now
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

sudo groupadd -f share-users
sudo usermod -aG share-users plex


############################################
# Virtualization directory structure
############################################

sudo groupadd -f virt-admin

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
# Systemd units
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


############################################
# Final notes
############################################

echo
echo 'Media server setup complete.'
echo '- Run /virtualization/container-services/start-services.sh manually the first time to generate .env and provide secrets.'
echo '- After the initial setup, squire-server-containers.service will handle container restarts.'
echo '- Run smbpasswd -a plex if the plex account needs Samba access.'
