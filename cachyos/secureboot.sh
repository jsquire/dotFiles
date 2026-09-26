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

if ! command -v limine-update &>/dev/null; then
    fail "limine-update not found. Is the CachyOS Limine tooling installed?"
    exit 1
fi

############################################
# Limine Secure Boot configuration
############################################

get_limine_config_path() {
    sudo bash -c '
        source /usr/lib/limine/limine-common-functions
        initialize_header >/dev/null
        printf "%s\n" "$LIMINE_CONFIG_PATH"
    '
}

enable_limine_config_enrollment() {
    local defaults_file=/etc/default/limine

    if sudo grep -qE '^[[:space:]]*ENABLE_ENROLL_LIMINE_CONFIG[[:space:]]*=[[:space:]]*yes[[:space:]]*$' "$defaults_file"; then
        success "Limine config enrollment already enabled"
        return
    fi

    info "Enabling Limine config enrollment..."
    if sudo grep -qE '^[[:space:]#]*ENABLE_ENROLL_LIMINE_CONFIG[[:space:]]*=' "$defaults_file"; then
        sudo sed -i -E \
            's|^[[:space:]#]*ENABLE_ENROLL_LIMINE_CONFIG[[:space:]]*=.*$|ENABLE_ENROLL_LIMINE_CONFIG=yes|' \
            "$defaults_file"
    else
        printf '\nENABLE_ENROLL_LIMINE_CONFIG=yes\n' | sudo tee -a "$defaults_file" >/dev/null
    fi
    success "Limine config enrollment enabled"
}

hash_limine_wallpaper() {
    local config_path wallpaper_ref wallpaper_path wallpaper_hash escaped_ref

    config_path=$(get_limine_config_path)
    if [[ ! -f "$config_path" ]]; then
        fail "Limine config not found at '$config_path'."
        return 1
    fi

    wallpaper_ref=$(sudo sed -nE \
        's|^[[:space:]]*wallpaper:[[:space:]]*([^[:space:]#]+)(#[[:xdigit:]]+)?[[:space:]]*$|\1|p' \
        "$config_path" | head -1)

    if [[ -z "$wallpaper_ref" ]]; then
        warn "No Limine wallpaper entry found in '$config_path'; skipping wallpaper hashing."
        return
    fi

    if [[ "$wallpaper_ref" != boot\(\):/* ]]; then
        fail "Unsupported Limine wallpaper reference: '$wallpaper_ref'"
        fail "Expected a boot(): path so the wallpaper file can be verified."
        return 1
    fi

    wallpaper_path="$(dirname "$config_path")/${wallpaper_ref#boot():/}"
    if [[ ! -f "$wallpaper_path" ]]; then
        fail "Limine wallpaper not found at '$wallpaper_path'."
        return 1
    fi

    wallpaper_hash=$(sudo b2sum "$wallpaper_path" | awk '{print $1}')
    escaped_ref=${wallpaper_ref//\\/\\\\}
    escaped_ref=${escaped_ref//&/\\&}
    escaped_ref=${escaped_ref//|/\\|}

    info "Adding the Limine wallpaper hash to '$config_path'..."
    sudo sed -i -E \
        "s|^[[:space:]]*wallpaper:[[:space:]]*.*$|wallpaper: ${escaped_ref}#${wallpaper_hash}|" \
        "$config_path"
    success "Limine wallpaper hash updated"
}

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

    # Retain Microsoft trust for Windows and the firmware's built-in OEM keys.
    info "Enrolling keys (with Microsoft and firmware-builtin keys included)..."
    sudo sbctl enroll-keys --microsoft --firmware-builtin
    success "Keys enrolled"

    enable_limine_config_enrollment
    hash_limine_wallpaper

    info "Updating Limine..."
    sudo limine-update
    success "Limine updated"

    # limine-update may replace the EFI binary, so enroll and sign the final binary.
    info "Enrolling the Limine config and signing the boot manager..."
    sudo limine-enroll-config
    success "Limine config enrolled"

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
info "  MSI X870E motherboards (Click BIOS X):"
info "    1. Press F7 to switch to Advanced Mode"
info "    2. Open Settings > Security > Secure Boot"
info "    3. Set Secure Boot Mode to 'Custom'"
info "    4. Open Key Management"
info "    5. Select 'Export Secure Boot variables' to make a backup"
info "    6. Select 'Reset to Setup Mode' and confirm"
info "       Do not select 'Restore Factory Keys'"
info "    7. Press F10, save changes, and reboot"
echo ""
info "After rebooting, run this script again to continue."
echo ""

if confirm "Reboot into firmware settings now? (systemctl reboot --firmware-setup)"; then
    sudo systemctl reboot --firmware-setup
fi
