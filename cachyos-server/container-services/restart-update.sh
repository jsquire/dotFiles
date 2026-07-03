#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

docker compose down
docker compose pull --ignore-pull-failures --include-deps
"$SCRIPT_DIR/start-services.sh" --force-recreate --build

docker image prune -f

# AdGuard Home refreshes its own blocklists on the schedule set in
# AdGuardHome.yaml (filters_update_interval), so no manual list update is needed
# here (this is the AdGuard equivalent of the old Pi-hole gravity update).
