#!/bin/bash

set -euo pipefail

############################################
# Microsoft Surface Laptop Support
#
# This script installs and configures the
# linux-surface kernel and related tools.
# Safe to run on non-Surface hardware (will skip).
############################################

############################################
# Helper functions
############################################

service_enable_now() {
    systemctl is-enabled "$1" &>/dev/null || sudo systemctl enable "$1" --now
}

############################################
# Surface Repository Setup
############################################

SURFACE_KEY="56C464BAAC421453"
SURFACE_REPO_NAME="linux-surface"
SURFACE_REPO_URL="https://pkg.surfacelinux.com/arch/"

# Import signing key if missing
if ! sudo pacman-key --list-keys "$SURFACE_KEY" &>/dev/null; then
    echo "Importing linux-surface signing key..."
    sudo pacman-key --recv-keys "$SURFACE_KEY"
    sudo pacman-key --lsign-key "$SURFACE_KEY"
else
    echo "linux-surface signing key already present"
fi

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
sudo pacman -Sy --noconfirm

############################################
# Surface Hardware Detection & Install
############################################

if sudo dmidecode | grep -qi "Surface"; then
    echo "Surface hardware detected"

    sudo pacman -S --needed --noconfirm \
        linux-surface \
        linux-surface-headers \
        iptsd \
        power-profiles-daemon

    # Only enable Surface-specific services if running the Surface kernel
    # (iptsd requires the ipts kernel module only present in linux-surface)
    if uname -r | grep -q "surface"; then
        echo "Surface kernel active — enabling services"
        service_enable_now iptsd
        service_enable_now power-profiles-daemon
    else
        echo "Surface kernel installed but not active"
        echo "Reboot into linux-surface kernel, then re-run this script to enable services"
    fi

else
    echo "Surface hardware not detected — skipping Surface kernel installation"
fi
