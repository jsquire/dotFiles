#!/bin/bash

set -euo pipefail

############################################
# Microsoft Surface Laptop Support
#
# This script installs and configures the
# linux-surface kernel and related tools.
# Non-Surface hardware exits before any persistent change.
############################################

if ! grep -qi "Surface" \
    /sys/class/dmi/id/product_name \
    /sys/class/dmi/id/product_family 2>/dev/null; then
    echo "Surface hardware not detected; no changes made."
    exit 0
fi

echo "Surface hardware detected"

############################################
# Helper functions
############################################

service_enable_now() {
    sudo systemctl enable "$1" --now
}

############################################
# Surface Repository Setup
############################################

SURFACE_KEY_FINGERPRINT="87DEFA4AB94A99A4C8C3112556C464BAAC421453"
SURFACE_KEY_URL="https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc"
SURFACE_REPO_NAME="linux-surface"
SURFACE_REPO_URL="https://pkg.surfacelinux.com/arch/"
TEMP_KEY=""

cleanup() {
    if [ -n "$TEMP_KEY" ] && [ -f "$TEMP_KEY" ]; then
        rm -f "$TEMP_KEY"
    fi
}

trap cleanup EXIT

for command_name in awk curl gpg grep pacman-conf pacman-key; do
    command -v "$command_name" &>/dev/null || {
        echo "ERROR: required command not found: $command_name" >&2
        exit 1
    }
done

TEMP_KEY="$(mktemp -t linux-surface-key.XXXXXXXX.asc)"
curl -fsSL "$SURFACE_KEY_URL" -o "$TEMP_KEY"

downloaded_fingerprint="$(
    gpg --show-keys --with-colons --fingerprint "$TEMP_KEY" 2>/dev/null |
        awk -F: '$1 == "fpr" && !found { print $10; found = 1 }'
)"
[ "$downloaded_fingerprint" = "$SURFACE_KEY_FINGERPRINT" ] || {
    echo "ERROR: the downloaded linux-surface key fingerprint did not match." >&2
    exit 1
}

# Import signing key if missing
if ! sudo pacman-key --list-keys "$SURFACE_KEY_FINGERPRINT" &>/dev/null; then
    echo "Importing linux-surface signing key..."
    sudo pacman-key --add "$TEMP_KEY"
else
    echo "linux-surface signing key already present"
fi

installed_fingerprint="$(
    sudo gpg --homedir /etc/pacman.d/gnupg --with-colons \
        --fingerprint "$SURFACE_KEY_FINGERPRINT" 2>/dev/null |
        awk -F: '$1 == "fpr" && !found { print $10; found = 1 }'
)"
[ "$installed_fingerprint" = "$SURFACE_KEY_FINGERPRINT" ] || {
    echo "ERROR: the pacman keyring contains an unexpected linux-surface key." >&2
    exit 1
}

sudo pacman-key --lsign-key "$SURFACE_KEY_FINGERPRINT"

# Add repo if missing
if ! pacman-conf --repo-list | grep -qx "$SURFACE_REPO_NAME"; then
    echo "Adding linux-surface repository..."

    sudo tee -a /etc/pacman.conf >/dev/null <<EOF

[$SURFACE_REPO_NAME]
Server = $SURFACE_REPO_URL
EOF

else
    echo "linux-surface repository already configured"
fi

# Sync package database
sudo pacman -Syu --noconfirm

############################################
# Surface Install
############################################

sudo pacman -S --needed --noconfirm \
    linux-surface \
    linux-surface-headers \
    iptsd \
    power-profiles-daemon

# Only enable Surface-specific services if running the Surface kernel
# (iptsd requires the ipts kernel module only present in linux-surface)
if uname -r | grep -q "surface"; then
    echo "Surface kernel active; enabling services"
    service_enable_now iptsd
    service_enable_now power-profiles-daemon
else
    echo "Surface kernel installed but not active"
    echo "Reboot into linux-surface kernel, then re-run this script to enable services"
fi
