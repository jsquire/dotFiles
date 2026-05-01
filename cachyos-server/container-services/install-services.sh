#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONTAINER_SERVICES_ROOT="${1:-$SCRIPT_DIR}"
PIHOLE_ROOT="${2:-/virtualization/pihole}"
SERVICE_UNIT=/etc/systemd/system/squire-server-containers.service
UPDATE_SERVICE_UNIT=/etc/systemd/system/squire-server-containers-update.service
TIMER_UNIT=/etc/systemd/system/squire-server-containers-update.timer

chmod +x "$CONTAINER_SERVICES_ROOT"/*.sh
mkdir -p "$PIHOLE_ROOT/root" "$PIHOLE_ROOT/log"
chmod 0755 "$PIHOLE_ROOT/log"
touch "$PIHOLE_ROOT/log/pihole.log"
chmod 0664 "$PIHOLE_ROOT/log/pihole.log"

cat <<EOF > "$SERVICE_UNIT"
[Unit]
Description=Squire Server Container Services
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$CONTAINER_SERVICES_ROOT
ExecStart=$CONTAINER_SERVICES_ROOT/start-services.sh --force-recreate --build
ExecStop=/usr/bin/docker compose -f $CONTAINER_SERVICES_ROOT/docker-compose.yml down
TimeoutStartSec=300
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > "$UPDATE_SERVICE_UNIT"
[Unit]
Description=Update Squire Server Container Services
After=docker.service network-online.target squire-server-containers.service
Requires=docker.service
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=$CONTAINER_SERVICES_ROOT
ExecStart=$CONTAINER_SERVICES_ROOT/restart-update.sh
TimeoutStartSec=1800
EOF

cat <<EOF > "$TIMER_UNIT"
[Unit]
Description=Weekly update for Squire Server Container Services

[Timer]
OnCalendar=Sat *-*-* 01:00:00
Persistent=true
Unit=squire-server-containers-update.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now squire-server-containers.service
systemctl enable --now squire-server-containers-update.timer
