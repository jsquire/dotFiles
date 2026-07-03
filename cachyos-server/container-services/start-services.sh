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
ADGUARD_BASE="${ADGUARD_BASE:-/srv/squire-server/adguard}"
PLEX_BASE="${PLEX_BASE:-/srv/squire-server/plex}"
PLEX_MEDIA="${PLEX_MEDIA:-/mnt/plex-media}"
PLEX_TRANSCODE="${PLEX_TRANSCODE:-/mnt/transcode}"
PLEX_HOSTNAME="${PLEX_HOSTNAME:-Squire-Media}"
PLEX_UID="${PLEX_UID:-$(id -u plex 2>/dev/null || id -u)}"
PLEX_GID="${PLEX_GID:-$(id -g plex 2>/dev/null || id -g)}"
PLEX_CLAIM_FILE="${PLEX_CLAIM_FILE:-$SCRIPT_DIR/.plex-claim}"
PLEX_CLAIM=$(read_secret "${PLEX_CLAIM:-}" "$PLEX_CLAIM_FILE" "Plex claim token" "CHANGE_ME_PLEX_CLAIM")

umask 077
cat <<EOF > .env
# General
SERVER_IP=$IP
SERVER_IP_V6=$IP6
LOCAL_DOMAIN=$LOCAL_DOMAIN
TZ=$TZ

# AdGuard Home
ADGUARD_BASE=$ADGUARD_BASE

# Plex
PLEX_BASE=$PLEX_BASE
PLEX_MEDIA=$PLEX_MEDIA
PLEX_TRANSCODE=$PLEX_TRANSCODE
PLEX_CLAIM=$PLEX_CLAIM
PLEX_HOSTNAME=$PLEX_HOSTNAME
PLEX_UID=$PLEX_UID
PLEX_GID=$PLEX_GID
EOF

# Pre-seed AdGuard Home configuration on first deploy so it comes up fully
# configured (DoH upstreams + blocklists) without the setup wizard. Idempotent:
# only runs when the config does not already exist. The admin password is read
# the same way as other secrets (env var, .adguard-admin-pass file, interactive
# prompt, or a placeholder for non-interactive runs) and bcrypt-hashed via the
# httpd image so no host packages are required.
AGH_CONF_DIR="${ADGUARD_BASE}/conf"
AGH_CONF="${AGH_CONF_DIR}/AdGuardHome.yaml"
AGH_TEMPLATE="${SCRIPT_DIR}/AdGuardHome.yaml"
AGH_ADMIN_USER="${AGH_ADMIN_USER:-admin}"
AGH_ADMIN_PASS_FILE="${AGH_ADMIN_PASS_FILE:-$SCRIPT_DIR/.adguard-admin-pass}"

if [ -f "$AGH_TEMPLATE" ] && [ ! -f "$AGH_CONF" ]; then
  mkdir -p "$AGH_CONF_DIR"
  AGH_ADMIN_PASS=$(read_secret "${AGH_ADMIN_PASS:-}" "$AGH_ADMIN_PASS_FILE" "AdGuard Home admin password" "CHANGE_ME_ADGUARD_PASSWORD")
  AGH_HASH="$(docker run --rm httpd:alpine htpasswd -nbB "$AGH_ADMIN_USER" "$AGH_ADMIN_PASS" 2>/dev/null | cut -d: -f2 || true)"
  if [ -n "$AGH_HASH" ]; then
    AGH_USER="$AGH_ADMIN_USER" AGH_HASH="$AGH_HASH" awk '
      { gsub(/__ADMIN_USER__/, ENVIRON["AGH_USER"]);
        gsub(/__ADMIN_PASSWORD_BCRYPT__/, ENVIRON["AGH_HASH"]);
        print }' "$AGH_TEMPLATE" > "$AGH_CONF"
    echo "Pre-seeded AdGuard Home config at $AGH_CONF (admin user: $AGH_ADMIN_USER)."
  else
    cp "$AGH_TEMPLATE" "$AGH_CONF"
    echo "WARNING: could not generate the AdGuard Home admin password hash." >&2
    echo "         Copied the template verbatim; finish setup via the wizard at http://<server>:3000" >&2
    echo "         or replace the __ADMIN_USER__/__ADMIN_PASSWORD_BCRYPT__ placeholders in $AGH_CONF." >&2
  fi
fi

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
