#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONTAINER_SERVICES_ROOT="${1:-$SCRIPT_DIR}"
SERVICE_UNIT=/etc/systemd/system/squire-server-containers.service
UPDATE_SERVICE_UNIT=/etc/systemd/system/squire-server-containers-update.service
TIMER_UNIT=/etc/systemd/system/squire-server-containers-update.timer

/usr/bin/docker compose -f "$CONTAINER_SERVICES_ROOT/docker-compose.yml" down || true
systemctl disable --now squire-server-containers-update.timer || true
systemctl stop squire-server-containers-update.service || true
systemctl disable --now squire-server-containers.service || true
rm -f "$TIMER_UNIT" "$UPDATE_SERVICE_UNIT" "$SERVICE_UNIT"
systemctl daemon-reload
systemctl reset-failed
