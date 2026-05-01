#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$SCRIPT_DIR"

read_secret() {
  local value="${1:-}"
  local file_path="$2"
  local prompt="$3"
  local placeholder="$4"

  if [ -n "$value" ]; then
    printf '%s' "$value"
    return 0
  fi

  if [ -f "$file_path" ]; then
    tr -d '\r\n' < "$file_path"
    return 0
  fi

  if [ -t 0 ]; then
    read -r -s -p "$prompt: " value
    printf '\n' >&2
    printf '%s' "$value"
    return 0
  fi

  printf 'Warning: %s was not provided; writing placeholder to .env\n' "$prompt" >&2
  printf '%s' "$placeholder"
}


IFACE="${IFACE:-$(ip route get 1.1.1.1 | awk '{print $5; exit}')}"
if [ -z "$IFACE" ]; then
  echo "Unable to detect the primary network interface." >&2
  exit 1
fi

IP="${SERVER_IP:-$(ip -4 addr show dev "$IFACE" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)}"
if [ -z "$IP" ]; then
  echo "Unable to detect an IPv4 address for interface $IFACE." >&2
  exit 1
fi

IP6="${SERVER_IP_V6:-$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)}"

LOCAL_DOMAIN="${LOCAL_DOMAIN:-local}"
TZ="${TZ:-America/New_York}"
PIHOLE_BASE="${PIHOLE_BASE:-/virtualization/pihole}"
PLEX_BASE="${PLEX_BASE:-/virtualization/plex}"
PLEX_MEDIA="${PLEX_MEDIA:-/storage/media}"
PLEX_TRANSCODE="${PLEX_TRANSCODE:-/mnt/transcode}"
PLEX_HOSTNAME="${PLEX_HOSTNAME:-Squire-Media}"
PLEX_UID="${PLEX_UID:-$(id -u plex 2>/dev/null || id -u)}"
PLEX_GID="${PLEX_GID:-$(id -g plex 2>/dev/null || id -g)}"
PIHOLE_ADMIN_PASS_FILE="${PIHOLE_ADMIN_PASS_FILE:-$SCRIPT_DIR/.pihole-admin-pass}"
PLEX_CLAIM_FILE="${PLEX_CLAIM_FILE:-$SCRIPT_DIR/.plex-claim}"
PIHOLE_ADMIN_PASS=$(read_secret "${PIHOLE_ADMIN_PASS:-}" "$PIHOLE_ADMIN_PASS_FILE" "Pi-hole admin password" "CHANGE_ME_PIHOLE_PASSWORD")
PLEX_CLAIM=$(read_secret "${PLEX_CLAIM:-}" "$PLEX_CLAIM_FILE" "Plex claim token" "CHANGE_ME_PLEX_CLAIM")

umask 077
cat <<EOF > .env
# General
SERVER_IP=$IP
SERVER_IP_V6=$IP6
LOCAL_DOMAIN=$LOCAL_DOMAIN
TZ=$TZ

# Pi-Hole
PIHOLE_BASE=$PIHOLE_BASE
PIHOLE_ADMIN_PASS=$PIHOLE_ADMIN_PASS

# Plex
PLEX_BASE=$PLEX_BASE
PLEX_MEDIA=$PLEX_MEDIA
PLEX_TRANSCODE=$PLEX_TRANSCODE
PLEX_CLAIM=$PLEX_CLAIM
PLEX_HOSTNAME=$PLEX_HOSTNAME
PLEX_UID=$PLEX_UID
PLEX_GID=$PLEX_GID
EOF

compose_args=()
wait_for_attach=false
for arg in "$@"; do
  if [ "$arg" = "--wait" ]; then
    wait_for_attach=true
    continue
  fi
  compose_args+=("$arg")
done

if [ "$wait_for_attach" = false ]; then
  compose_args=(-d "${compose_args[@]}")
fi

docker compose up "${compose_args[@]}"
