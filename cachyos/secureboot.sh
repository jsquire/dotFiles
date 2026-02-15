#!/bin/bash

set -euo pipefail

############################################
# Secure Boot Setup for CachyOS + Limine
#
# Multi-phase script that auto-detects
# progress and guides you through each step.
# Re-run after each reboot to continue.
#
# Reference: https://wiki.cachyos.org/configuration/secure_boot_setup/
############################################

############################################
# Colors & helpers
############################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${CYAN}ℹ ${NC}$*"; }
success() { echo -e "${GREEN}✓ ${NC}$*"; }
warn()    { echo -e "${YELLOW}⚠ ${NC}$*"; }
fail()    { echo -e "${RED}✗ ${NC}$*"; }

confirm() {
    echo ""
    read -rp "$(echo -e "${YELLOW}▸${NC} $1 [y/N] ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

############################################
# Preflight checks
############################################

if [[ $EUID -eq 0 ]]; then
    fail "Do not run this script as root. It will use sudo when needed."
    exit 1
fi

if [[ ! -d /sys/firmware/efi ]]; then
    fail "This system is not booted in UEFI mode. Secure Boot requires UEFI."
    exit 1
fi

if ! command -v limine-enroll-config &>/dev/null; then
    fail "limine-enroll-config not found. Is Limine installed?"
    fail "This script is designed for CachyOS with the Limine boot manager."
    exit 1
fi

############################################
# Install sbctl if needed
############################################

if ! command -v sbctl &>/dev/null; then
    info "Installing sbctl (Secure Boot key manager)..."
    sudo pacman -S --needed --noconfirm sbctl
    success "sbctl installed"
else
    success "sbctl already installed"
fi

############################################
# Read current state
############################################

SBCTL_STATUS=$(sudo sbctl status 2>&1)

sbctl_field() {
    echo "$SBCTL_STATUS" | grep -i "$1" | head -1 | sed 's/.*[:\t]\s*//'
}

SETUP_MODE_RAW=$(sbctl_field "Setup Mode")
SECURE_BOOT_RAW=$(sbctl_field "Secure Boot")
INSTALLED_RAW=$(sbctl_field "Installed")

is_enabled() {
    [[ "$1" == *"✓"* ]] || [[ "$1" == *"Enabled"* ]]
}

SETUP_MODE_ON=false
SBCTL_INSTALLED=false
SECURE_BOOT_ON=false

# Setup Mode is active when sbctl reports "Setup Mode:  Enabled" (keys cleared).
if echo "$SBCTL_STATUS" | grep -qi "Setup Mode.*Enabled"; then
    SETUP_MODE_ON=true
fi

is_enabled "$INSTALLED_RAW" && SBCTL_INSTALLED=true
is_enabled "$SECURE_BOOT_RAW" && SECURE_BOOT_ON=true

echo ""
echo -e "${BOLD}Current Secure Boot Status:${NC}"
echo "$SBCTL_STATUS"
echo ""

############################################
# Phase 3: Already done — verify
############################################

if $SECURE_BOOT_ON; then
    success "Secure Boot is enabled! You're all set."
    echo ""
    info "Verifying signed files..."
    sudo sbctl verify || true
    echo ""
    info "You can also verify with: bootctl"
    exit 0
fi

############################################
# Phase 2: Setup Mode active — enroll keys
############################################

if $SETUP_MODE_ON; then
    success "Setup Mode is active. Ready to enroll Secure Boot keys."
    echo ""

    if ! confirm "Create and enroll Secure Boot keys now?"; then
        info "Aborted. Re-run this script when ready."
        exit 0
    fi

    if $SBCTL_INSTALLED; then
        success "Secure Boot keys already exist — skipping creation"
    else
        info "Creating Secure Boot keys..."
        sudo sbctl create-keys
        success "Keys created"
    fi

    # --microsoft includes Microsoft's keys (needed for firmware updates and dual-boot)
    info "Enrolling keys (with Microsoft's keys included)..."
    sudo sbctl enroll-keys --microsoft
    success "Keys enrolled"

    # Limine uses BLAKE2B hash verification — only its EFI binary needs signing, not kernel images
    info "Signing Limine boot manager..."
    sudo limine-enroll-config
    success "Limine config enrolled"

    info "Updating Limine..."
    sudo limine-update
    success "Limine updated"

    echo ""
    info "Verifying signed files..."
    sudo sbctl verify || true
    echo ""

    warn "═══════════════════════════════════════════════════════════════"
    warn "  NEXT STEP: Reboot and enable Secure Boot in UEFI/BIOS"
    warn "═══════════════════════════════════════════════════════════════"
    echo ""
    info "  1. Enter your UEFI/BIOS firmware settings"
    info "  2. Find Secure Boot options"
    info "  3. Enable Secure Boot (use 'Custom' mode if your firmware offers it)"
    info "  4. Save and exit"
    echo ""
    info "After rebooting, run this script again to verify."
    echo ""

    if confirm "Reboot now?"; then
        sudo systemctl reboot
    fi

    exit 0
fi

############################################
# Phase 1: Need Setup Mode — guide reboot
############################################

warn "Secure Boot is disabled and Setup Mode is not active."
warn "You need to clear the existing Secure Boot keys in your UEFI firmware."
echo ""
warn "═══════════════════════════════════════════════════════════════"
warn "  NEXT STEP: Reboot into UEFI and enter Secure Boot Setup Mode"
warn "═══════════════════════════════════════════════════════════════"
echo ""
info "  Most motherboards:"
info "    1. Enter your UEFI/BIOS firmware settings"
info "    2. Find Secure Boot settings"
info "    3. Clear/delete all Secure Boot keys or select 'Reset to Setup Mode'"
info "       (wording varies by manufacturer)"
info "    4. Save and exit"
echo ""
info "  MSI motherboards (no 'Setup Mode' option):"
info "    1. Set Secure Boot Mode to 'Custom'"
info "    2. Enter Key Management and delete all keys"
info "    3. Save and exit"
echo ""
info "After rebooting, run this script again to continue."
echo ""

if confirm "Reboot into firmware settings now? (systemctl reboot --firmware-setup)"; then
    sudo systemctl reboot --firmware-setup
fi
