#!/bin/bash

set -euo pipefail

############################################
# Kopia Full Disaster Recovery
#
# Restores a complete system from Kopia
# backup after a fresh CachyOS install.
#
# Prerequisites:
#   - CachyOS installed
#   - bootstrap.sh has been run
#   - Samba share mounted at /mnt/squire-server
#
# Run with: sudo ./kopia-restore-full.sh
############################################

BACKUP_USER="jesse"
BACKUP_HOME="/home/jesse"
REPO_PATH="/mnt/squire-server/backups/cachyos"
MOUNT_POINT="/mnt/squire-server"
STAGING_DIR="/tmp/kopia-restore-staging"

############################################
# Must run as root
############################################

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo."
    exit 1
fi

# Ensure kopia uses root's config regardless of how sudo handles HOME
export HOME=/root

echo ""
echo "══════════════════════════════════════════"
echo "  Kopia Full Disaster Recovery"
echo "══════════════════════════════════════════"
echo ""

############################################
# Verify prerequisites
############################################

echo "── Checking prerequisites ──"

if ! command -v kopia &>/dev/null; then
    echo "ERROR: kopia is not installed."
    echo "Run bootstrap.sh and kopia-backup.sh first, or:"
    echo "  yay -S kopia-bin"
    exit 1
fi
echo "  ✓ kopia installed ($(kopia --version 2>/dev/null | head -1))"

if ! findmnt -n "${MOUNT_POINT}" &>/dev/null; then
    echo "ERROR: Samba share not mounted at ${MOUNT_POINT}."
    echo "Mount it first, or see backups/ReadMe.md for setup instructions."
    exit 1
fi
echo "  ✓ Samba share mounted at ${MOUNT_POINT}"

if [[ ! -d "${REPO_PATH}" ]]; then
    echo "ERROR: Repository path not found: ${REPO_PATH}"
    exit 1
fi
echo "  ✓ Repository path exists"

if ! id "${BACKUP_USER}" &>/dev/null; then
    echo "ERROR: User '${BACKUP_USER}' does not exist."
    exit 1
fi
echo "  ✓ User '${BACKUP_USER}' exists"

############################################
# Connect to repository
############################################

echo ""
echo "── Connecting to Kopia repository ──"

if [[ ! -f /root/.config/kopia/repository.config ]]; then
    echo "Repository: ${REPO_PATH}"
    echo ""
    kopia repository connect filesystem --path="${REPO_PATH}"
    echo "Connected."
else
    CONNECTED_PATH=$(kopia repository status --json 2>/dev/null | grep -oP '"path"\s*:\s*"\K[^"]+' || true)
    if [[ -n "${CONNECTED_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}/" ]]; then
        echo "Reconnecting from ${CONNECTED_PATH} to ${REPO_PATH}..."
        kopia repository disconnect
        kopia repository connect filesystem --path="${REPO_PATH}"
    else
        echo "Already connected to ${REPO_PATH}."
    fi
fi

############################################
# List available snapshots
############################################

echo ""
echo "── Available Snapshots ──"
echo ""

kopia snapshot list --all
echo ""

############################################
# Get manifest IDs for each source
############################################

get_latest_manifest() {
    local source_path="$1"
    kopia snapshot list "${source_path}" --manifest-id 2>/dev/null | grep -oP '\bk[0-9a-f]+\b' | tail -1
}

HOME_MANIFEST=$(get_latest_manifest "${BACKUP_HOME}")
ETC_MANIFEST=$(get_latest_manifest "/etc")
BOOT_MANIFEST=$(get_latest_manifest "/boot")

echo ""
echo "── Selected Snapshots ──"
echo "  /home/jesse:  ${HOME_MANIFEST:-NOT FOUND}"
echo "  /etc:         ${ETC_MANIFEST:-NOT FOUND}"
echo "  /boot:        ${BOOT_MANIFEST:-NOT FOUND}"
echo ""

if [[ -z "${HOME_MANIFEST}" ]]; then
    echo "ERROR: No /home snapshot found. Cannot proceed with recovery."
    exit 1
fi

############################################
# Phase 1: Restore and apply manifests
############################################

echo "── Phase 1: System Manifests ──"
echo ""

if [[ -n "${HOME_MANIFEST}" ]]; then
    # Restore just the manifest directory first
    MANIFEST_SUBPATH=".local/share/system-backup/manifests"
    mkdir -p "${STAGING_DIR}/manifests"

    echo "Extracting package manifests from backup..."
    kopia restore "${HOME_MANIFEST}/${MANIFEST_SUBPATH}" "${STAGING_DIR}/manifests" --skip-existing 2>/dev/null || true

    # Show package drift
    if [[ -f "${STAGING_DIR}/manifests/pkglist-explicit.txt" ]]; then
        echo ""
        echo "── Package Comparison ──"

        CURRENT_PKGS=$(mktemp)
        BACKUP_PKGS="${STAGING_DIR}/manifests/pkglist-explicit.txt"
        pacman -Qe --quiet > "${CURRENT_PKGS}"

        MISSING_PKGS=$(comm -23 <(sort "${BACKUP_PKGS}") <(sort "${CURRENT_PKGS}") || true)
        EXTRA_PKGS=$(comm -13 <(sort "${BACKUP_PKGS}") <(sort "${CURRENT_PKGS}") || true)

        if [[ -n "${MISSING_PKGS}" ]]; then
            MISSING_COUNT=$(echo "${MISSING_PKGS}" | wc -l)
            echo ""
            echo "  Packages in backup but NOT currently installed (${MISSING_COUNT}):"
            echo "${MISSING_PKGS}" | sed 's/^/    /'
            echo ""
            read -rp "  Install missing packages? [y/N] " INSTALL_MISSING
            if [[ "${INSTALL_MISSING,,}" =~ ^y ]]; then
                echo "  Installing..."
                # shellcheck disable=SC2086
                sudo -u "${BACKUP_USER}" yay -S --needed --noconfirm ${MISSING_PKGS} || echo "  WARNING: Some packages failed to install"
            fi
        else
            echo "  All backed-up packages are already installed."
        fi

        if [[ -n "${EXTRA_PKGS}" ]]; then
            EXTRA_COUNT=$(echo "${EXTRA_PKGS}" | wc -l)
            echo ""
            echo "  Packages installed now but NOT in backup (${EXTRA_COUNT}):"
            echo "${EXTRA_PKGS}" | sed 's/^/    /'
            echo "  (These are new additions since the backup — no action needed.)"
        fi

        rm -f "${CURRENT_PKGS}"
    fi

    # Show AUR packages
    if [[ -f "${STAGING_DIR}/manifests/pkglist-aur.txt" ]]; then
        echo ""
        echo "── AUR Packages from Backup ──"
        CURRENT_AUR=$(mktemp)
        pacman -Qm --quiet > "${CURRENT_AUR}" 2>/dev/null || true
        MISSING_AUR=$(comm -23 <(sort "${STAGING_DIR}/manifests/pkglist-aur.txt") <(sort "${CURRENT_AUR}") || true)

        if [[ -n "${MISSING_AUR}" ]]; then
            echo "  Missing AUR packages:"
            echo "${MISSING_AUR}" | sed 's/^/    /'
            echo ""
            read -rp "  Install missing AUR packages? [y/N] " INSTALL_AUR
            if [[ "${INSTALL_AUR,,}" =~ ^y ]]; then
                # shellcheck disable=SC2086
                sudo -u "${BACKUP_USER}" yay -S --needed --noconfirm ${MISSING_AUR} || echo "  WARNING: Some AUR packages failed to install"
            fi
        else
            echo "  All backed-up AUR packages are already installed."
        fi
        rm -f "${CURRENT_AUR}"
    fi

    # Show Flatpak apps
    if [[ -f "${STAGING_DIR}/manifests/flatpak-apps.txt" ]]; then
        echo ""
        echo "── Flatpak Apps from Backup ──"
        CURRENT_FLATPAK=$(mktemp)
        flatpak list --app --columns=application > "${CURRENT_FLATPAK}" 2>/dev/null || true
        MISSING_FLATPAK=$(comm -23 <(sort "${STAGING_DIR}/manifests/flatpak-apps.txt") <(sort "${CURRENT_FLATPAK}") || true)

        if [[ -n "${MISSING_FLATPAK}" ]]; then
            echo "  Missing Flatpak apps:"
            echo "${MISSING_FLATPAK}" | sed 's/^/    /'
            echo ""
            read -rp "  Install missing Flatpak apps? [y/N] " INSTALL_FLATPAK
            if [[ "${INSTALL_FLATPAK,,}" =~ ^y ]]; then
                echo "${MISSING_FLATPAK}" | while read -r APP; do
                    flatpak install -y flathub "${APP}" || echo "  WARNING: Failed to install ${APP}"
                done
            fi
        else
            echo "  All backed-up Flatpak apps are already installed."
        fi
        rm -f "${CURRENT_FLATPAK}"
    fi
fi

############################################
# Phase 2: Restore /etc (staged)
############################################

echo ""
echo "── Phase 2: System Configuration (/etc) ──"
echo ""

if [[ -n "${ETC_MANIFEST}" ]]; then
    ETC_STAGING="${STAGING_DIR}/etc"
    mkdir -p "${ETC_STAGING}"

    echo "Restoring /etc to staging directory..."
    kopia restore "${ETC_MANIFEST}" "${ETC_STAGING}" --overwrite-files

    echo ""
    echo "Staged /etc restored to: ${ETC_STAGING}"
    echo ""
    echo "The following will be selectively restored:"
    echo "  ✓ NetworkManager connections"
    echo "  ✓ systemd custom units"
    echo "  ✓ Snapper configs"
    echo "  ✓ logrotate custom configs"
    echo "  ✓ samba credentials setup"
    echo ""
    echo "The following will be SKIPPED (fresh install values are correct):"
    echo "  ✗ machine-id, hostname, locale, timezone"
    echo "  ✗ bootloader configs (grub, systemd-boot)"
    echo "  ✗ crypttab, mkinitcpio"
    echo "  ✗ passwd, shadow, group (user was created by bootstrap)"
    echo ""
    read -rp "Proceed with selective /etc restore? [Y/n] " ETC_CONFIRM

    if [[ ! "${ETC_CONFIRM,,}" =~ ^n ]]; then
        # NetworkManager connections
        if [[ -d "${ETC_STAGING}/NetworkManager/system-connections" ]]; then
            echo "  Restoring NetworkManager connections..."
            cp -a "${ETC_STAGING}/NetworkManager/system-connections/"* /etc/NetworkManager/system-connections/ 2>/dev/null || true
        fi

        # Custom systemd units
        if [[ -d "${ETC_STAGING}/systemd/system" ]]; then
            echo "  Restoring custom systemd units..."
            find "${ETC_STAGING}/systemd/system" -maxdepth 1 -type f \( -name "*.service" -o -name "*.timer" \) | while read -r UNIT; do
                UNIT_NAME=$(basename "${UNIT}")
                # Skip units that ship with packages
                if [[ ! -f "/usr/lib/systemd/system/${UNIT_NAME}" ]]; then
                    cp -a "${UNIT}" /etc/systemd/system/
                    echo "    Restored: ${UNIT_NAME}"
                fi
            done
        fi

        # Snapper configs
        if [[ -d "${ETC_STAGING}/snapper/configs" ]]; then
            echo "  Restoring snapper configs..."
            cp -a "${ETC_STAGING}/snapper/configs/"* /etc/snapper/configs/ 2>/dev/null || true
        fi

        # Custom logrotate configs
        if [[ -d "${ETC_STAGING}/logrotate.d" ]]; then
            echo "  Restoring custom logrotate configs..."
            for CONF in "${ETC_STAGING}/logrotate.d/"*; do
                [[ -e "${CONF}" ]] || continue
                CONF_NAME=$(basename "${CONF}")
                # Only restore configs not shipped by packages
                if ! pacman -Qo "/etc/logrotate.d/${CONF_NAME}" &>/dev/null; then
                    cp -a "${CONF}" /etc/logrotate.d/
                    echo "    Restored: ${CONF_NAME}"
                fi
            done
        fi

        # smbcredentials (if it was in /etc backup)
        if [[ -f "${ETC_STAGING}/samba/smb.conf" ]]; then
            echo "  Restoring samba config..."
            cp -a "${ETC_STAGING}/samba/smb.conf" /etc/samba/smb.conf 2>/dev/null || true
        fi

        echo "  Selective /etc restore complete."
        echo ""
        echo "  The full staged /etc is still available at:"
        echo "    ${ETC_STAGING}"
        echo "  Browse it to manually restore anything else you need."
    fi
else
    echo "No /etc snapshot found. Skipping."
fi

############################################
# Phase 3: Restore /home
############################################

echo ""
echo "── Phase 3: Home Directory ──"
echo ""

if [[ -n "${HOME_MANIFEST}" ]]; then
    echo "This will restore your home directory from backup."
    echo "  Source: snapshot ${HOME_MANIFEST}"
    echo "  Target: ${BACKUP_HOME}"
    echo ""

    echo "Restore mode:"
    echo "  1. Skip existing — only restore files that don't exist (safe, recommended)"
    echo "  2. Overwrite all — restore everything, overwriting current files"
    echo "  3. Skip — don't restore /home (if you only need packages and /etc)"
    echo ""
    read -rp "Select mode (1-3) [1]: " HOME_MODE
    HOME_MODE="${HOME_MODE:-1}"

    case "${HOME_MODE}" in
        1)
            echo ""
            echo "Restoring home directory (skip existing)..."
            kopia restore "${HOME_MANIFEST}" "${BACKUP_HOME}" --skip-existing
            echo "Home directory restored."
            echo "Fixing ownership on ${BACKUP_HOME}..."
            chown -R "${BACKUP_USER}:${BACKUP_USER}" "${BACKUP_HOME}"
            ;;
        2)
            echo ""
            read -rp "Are you sure you want to overwrite ALL files in ${BACKUP_HOME}? Type 'yes': " HOME_CONFIRM
            if [[ "${HOME_CONFIRM}" == "yes" ]]; then
                echo "Restoring home directory (overwrite)..."
                kopia restore "${HOME_MANIFEST}" "${BACKUP_HOME}" --overwrite-files --overwrite-directories --overwrite-symlinks
                echo "Home directory restored."
                echo "Fixing ownership on ${BACKUP_HOME}..."
                chown -R "${BACKUP_USER}:${BACKUP_USER}" "${BACKUP_HOME}"
            else
                echo "Skipped."
            fi
            ;;
        3)
            echo "Skipping home directory restore."
            ;;
        *)
            echo "Invalid selection. Skipping home directory."
            ;;
    esac
fi

############################################
# Phase 4: /boot (optional)
############################################

echo ""
echo "── Phase 4: Boot Partition ──"
echo ""

if [[ -n "${BOOT_MANIFEST}" ]]; then
    echo "A /boot snapshot is available. This is usually NOT needed after"
    echo "a fresh install (the installer sets up the bootloader correctly)."
    echo ""
    read -rp "Restore /boot? [y/N] " BOOT_CONFIRM
    if [[ "${BOOT_CONFIRM,,}" =~ ^y ]]; then
        echo "Restoring /boot..."
        kopia restore "${BOOT_MANIFEST}" /boot --overwrite-files
        echo "/boot restored. You may need to reinstall the bootloader."
    else
        echo "Skipping /boot (recommended)."
    fi
else
    echo "No /boot snapshot found. Skipping."
fi

############################################
# Phase 5: Re-establish backup schedule
############################################

echo ""
echo "── Phase 5: Re-establish Backups ──"
echo ""

BACKUP_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [[ -f "${BACKUP_SCRIPT_DIR}/kopia-backup.sh" ]]; then
    echo "To re-establish the nightly backup schedule, run:"
    echo ""
    echo "  sudo ${BACKUP_SCRIPT_DIR}/kopia-backup.sh"
    echo ""
    read -rp "Run it now? [y/N] " RUN_BACKUP
    if [[ "${RUN_BACKUP,,}" =~ ^y ]]; then
        bash "${BACKUP_SCRIPT_DIR}/kopia-backup.sh"
    fi
else
    echo "kopia-backup.sh not found in ${BACKUP_SCRIPT_DIR}."
    echo "Run it manually after recovery to re-establish the backup schedule."
fi

############################################
# Cleanup and summary
############################################

echo ""
echo "══════════════════════════════════════════"
echo "  Recovery Summary"
echo "══════════════════════════════════════════"
echo ""
echo "  Packages:    Manifests compared and installed"
echo "  /etc:        Selectively restored (staged copy at ${STAGING_DIR}/etc)"
echo "  /home:       Restored"
echo "  /boot:       $(if [[ -n "${BOOT_MANIFEST}" ]]; then echo "Available (check above)"; else echo "Not in backup"; fi)"
echo ""
echo "  Remaining manual steps:"
echo "    1. Review ${STAGING_DIR}/etc for any configs you want to manually merge"
echo "    2. Re-establish backup schedule (kopia-backup.sh) if not done above"
echo "    3. Reboot to apply all changes"
echo "    4. Delete staging dir when done: sudo rm -rf ${STAGING_DIR}"
echo ""
