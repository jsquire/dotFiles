#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

docker compose down
docker compose pull --ignore-pull-failures --include-deps
"$SCRIPT_DIR/start-services.sh" --force-recreate --build

docker image prune -f

if docker ps --format '{{.Names}}' | grep -qx 'pihole'; then
  for _ in $(seq 1 60); do
    if docker exec pihole pihole status >/dev/null 2>&1; then
      docker exec pihole pihole updateGravity
      break
    fi
    sleep 15
  done
fi
