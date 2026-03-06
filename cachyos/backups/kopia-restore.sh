#!/bin/bash

set -euo pipefail

############################################
# Kopia Selective Restore
#
# Interactive tool for browsing and
# restoring files from Kopia snapshots.
#
# Assumes bootstrap.sh has been run
# (kopia-bin installed).
#
# Run with: sudo ./kopia-restore.sh
############################################

REPO_PATH="/mnt/squire-server/backups/cachyos"
USERNAME="jesse"

############################################
# Must run as root
############################################

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run with sudo."
    exit 1
fi

# Ensure kopia uses root's config regardless of how sudo handles HOME
export HOME=/root

############################################
# Verify prerequisites
############################################

if ! command -v kopia &>/dev/null; then
    echo "ERROR: kopia is not installed. Run bootstrap.sh first."
    exit 1
fi

if [[ ! -d "${REPO_PATH}" ]]; then
    echo "ERROR: Repository path not found: ${REPO_PATH}"
    echo "Ensure the samba share is mounted."
    exit 1
fi

# Connect if needed, verify correct repo
if [[ ! -f /root/.config/kopia/repository.config ]]; then
    echo "Kopia is not connected to a repository."
    echo "Connecting to: ${REPO_PATH}"
    echo ""
    kopia repository connect filesystem --path="${REPO_PATH}"
    echo ""
else
    CONNECTED_PATH=$(kopia repository status --json 2>/dev/null | grep -oP '"path"\s*:\s*"\K[^"]+' || true)
    if [[ -n "${CONNECTED_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}" && "${CONNECTED_PATH}" != "${REPO_PATH}/" ]]; then
        echo "WARNING: Kopia is connected to a different repository."
        echo "  Connected: ${CONNECTED_PATH}"
        echo "  Expected:  ${REPO_PATH}"
        echo ""
        echo "Reconnecting to ${REPO_PATH}..."
        kopia repository disconnect
        kopia repository connect filesystem --path="${REPO_PATH}"
        echo ""
    fi
fi

############################################
# List snapshots and let user choose
############################################

echo ""
echo "── Kopia Selective Restore ──"
echo ""
echo "Fetching snapshots..."
echo ""

# Get snapshot list
SNAP_LIST=$(kopia snapshot list --all)

if [[ -z "${SNAP_LIST}" ]]; then
    echo "No snapshots found in repository."
    exit 1
fi

echo "${SNAP_LIST}"
echo ""

echo "── Available Sources ──"
echo ""

mapfile -t SOURCES < <(kopia snapshot list --all | grep -P '^\S+@\S+:' | sed 's/^ *//')

if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "No snapshot sources found."
    exit 1
fi

for i in "${!SOURCES[@]}"; do
    echo "  $((i + 1)). ${SOURCES[$i]}"
done

echo ""
read -rp "Select source (1-${#SOURCES[@]}): " SRC_CHOICE

if [[ ! "${SRC_CHOICE}" =~ ^[0-9]+$ ]] || (( SRC_CHOICE < 1 || SRC_CHOICE > ${#SOURCES[@]} )); then
    echo "Invalid selection."
    exit 1
fi

SELECTED_SOURCE="${SOURCES[$((SRC_CHOICE - 1))]}"

# Extract the path from the source line (format: user@host:/path)
SOURCE_PATH=$(echo "${SELECTED_SOURCE}" | grep -oP ':\K/.*' | sed 's/[[:space:]]*$//')

echo ""
echo "── Snapshots for ${SOURCE_PATH} ──"
echo ""

# List snapshots for selected source with manifest IDs
kopia snapshot list "${SOURCE_PATH}" --manifest-id

echo ""

# Get manifest IDs
mapfile -t MANIFESTS < <(kopia snapshot list "${SOURCE_PATH}" --manifest-id | grep -oP '\bk[0-9a-f]+\b')

if [[ ${#MANIFESTS[@]} -eq 0 ]]; then
    echo "No snapshots found for ${SOURCE_PATH}."
    exit 1
fi

echo "Enter a manifest ID from the list above, or 'latest' for the most recent:"
read -rp "Manifest ID: " MANIFEST_INPUT

if [[ "${MANIFEST_INPUT}" == "latest" ]]; then
    MANIFEST_ID="${MANIFESTS[-1]}"
    echo "Using latest: ${MANIFEST_ID}"
else
    MANIFEST_ID="${MANIFEST_INPUT}"
fi

############################################
# Choose restore mode
############################################

echo ""
echo "── Restore Mode ──"
echo ""
echo "  1. Browse — FUSE-mount the snapshot and open file manager"
echo "  2. Restore path — restore a specific file or directory"
echo "  3. Full restore — restore entire snapshot to original location"
echo ""
read -rp "Select mode (1-3): " MODE

case "${MODE}" in
    1)
        ############################################
        # Browse mode — FUSE mount
        ############################################
        MOUNT_DIR=$(mktemp -d /tmp/kopia-browse-XXXXXX)
        echo ""
        echo "Mounting snapshot to ${MOUNT_DIR}..."
        echo "Press Ctrl+C or close the file manager to unmount."
        echo ""

        cleanup_mount() {
            echo ""
            echo "Unmounting..."
            fusermount -u "${MOUNT_DIR}" 2>/dev/null || umount "${MOUNT_DIR}" 2>/dev/null || true
            wait "${MOUNT_PID}" 2>/dev/null || true
            rmdir "${MOUNT_DIR}" 2>/dev/null || true
            echo "Done."
        }

        # Mount in background, open file manager, then clean up
        kopia mount "${MANIFEST_ID}" "${MOUNT_DIR}" --fuse-allow-other &
        MOUNT_PID=$!
        trap cleanup_mount EXIT INT TERM

        # Wait for FUSE mount to become ready (up to 15s)
        for _ in $(seq 1 15); do
            mountpoint -q "${MOUNT_DIR}" 2>/dev/null && break
            sleep 1
        done

        if ! mountpoint -q "${MOUNT_DIR}" 2>/dev/null; then
            echo "ERROR: Failed to mount snapshot. Check the manifest ID and repository connection."
            exit 1
        fi

        if command -v dolphin &>/dev/null; then
            sudo -u "${USERNAME}" dolphin "${MOUNT_DIR}" || true
        elif command -v xdg-open &>/dev/null; then
            sudo -u "${USERNAME}" xdg-open "${MOUNT_DIR}" || true
        else
            echo "No file manager found. Browse manually at: ${MOUNT_DIR}"
            echo "Press Enter when done to unmount."
            read -r
        fi

        trap - EXIT INT TERM
        cleanup_mount
        ;;

    2)
        ############################################
        # Restore path mode
        ############################################
        echo ""
        echo "Enter the path to restore (relative to snapshot root)."
        echo "Examples:"
        echo "  .config/nvim"
        echo "  Documents/project"
        echo "  etc/NetworkManager/system-connections"
        echo ""
        read -rp "Path: " RESTORE_SUBPATH

        # Strip leading slash or ./
        RESTORE_SUBPATH="${RESTORE_SUBPATH#/}"
        RESTORE_SUBPATH="${RESTORE_SUBPATH#./}"

        DEFAULT_TARGET="${SOURCE_PATH}/${RESTORE_SUBPATH}"
        echo ""
        read -rp "Restore to [${DEFAULT_TARGET}]: " TARGET_PATH
        TARGET_PATH="${TARGET_PATH:-${DEFAULT_TARGET}}"

        echo ""
        echo "  Source:  ${MANIFEST_ID}/${RESTORE_SUBPATH}"
        echo "  Target:  ${TARGET_PATH}"
        echo ""

        read -rp "Overwrite existing files? [y/N] " OVERWRITE
        if [[ "${OVERWRITE,,}" =~ ^y ]]; then
            OW_FLAGS="--overwrite-files --overwrite-directories --overwrite-symlinks"
        else
            OW_FLAGS="--skip-existing"
        fi

        read -rp "Proceed? [Y/n] " CONFIRM
        if [[ "${CONFIRM,,}" =~ ^n ]]; then
            echo "Aborted."
            exit 0
        fi

        echo ""
        echo "Restoring..."
        # shellcheck disable=SC2086
        kopia restore "${MANIFEST_ID}/${RESTORE_SUBPATH}" "${TARGET_PATH}" ${OW_FLAGS}
        echo ""
        echo "Restore complete: ${TARGET_PATH}"
        ;;

    3)
        ############################################
        # Full restore mode
        ############################################
        echo ""
        echo "WARNING: This will restore the entire snapshot to its original location."
        echo "  Source path: ${SOURCE_PATH}"
        echo ""
        read -rp "Overwrite existing files? [y/N] " OVERWRITE
        if [[ "${OVERWRITE,,}" =~ ^y ]]; then
            OW_FLAGS="--overwrite-files --overwrite-directories --overwrite-symlinks"
        else
            OW_FLAGS="--skip-existing"
        fi

        echo ""
        echo "  Snapshot:  ${MANIFEST_ID}"
        echo "  Target:    ${SOURCE_PATH}"
        echo "  Mode:      ${OW_FLAGS}"
        echo ""
        read -rp "Are you sure? Type 'yes' to confirm: " CONFIRM
        if [[ "${CONFIRM}" != "yes" ]]; then
            echo "Aborted."
            exit 0
        fi

        echo ""
        echo "Restoring..."
        # shellcheck disable=SC2086
        kopia restore "${MANIFEST_ID}" "${SOURCE_PATH}" ${OW_FLAGS}
        echo ""
        echo "Full restore complete: ${SOURCE_PATH}"
        ;;

    *)
        echo "Invalid selection."
        exit 1
        ;;
esac
