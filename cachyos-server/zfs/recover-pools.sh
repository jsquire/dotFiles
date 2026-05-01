#!/usr/bin/env bash

set -euo pipefail

#
# Recover ZFS pools after an OS upgrade or reinstall.
#
# Common scenario: After a kernel update or OS reinstall, the zpool.cache is
# stale or missing and pools fail to auto-import.  This script scans disks
# by stable by-id paths, shows discoverable pools, and reimports them.
#
# Safe to run multiple times — importing an already-active pool is a no-op.
#
# Usage:
#   sudo ./recover-pools.sh          # Import known pools
#   sudo ./recover-pools.sh --scan   # Scan and show all importable pools first
#

KNOWN_POOLS=(storage-pool virt-pool)
SCAN_PATH="/dev/disk/by-id"

if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root (or via sudo)." >&2
    exit 1
fi


# Ensure ZFS kernel module is loaded
if ! lsmod | grep -q "^zfs "; then
    echo "Loading ZFS kernel module..."
    modprobe zfs
fi


scan_pools() {
    echo "=== Scanning for importable ZFS pools ==="
    echo
    zpool import -d "$SCAN_PATH" 2>/dev/null || true
    echo
}

import_pool() {
    local pool="$1"

    if zpool list -H -o name "$pool" &>/dev/null; then
        echo "Pool '$pool' is already imported and online."
        return 0
    fi

    echo "Attempting to import pool '$pool'..."

    if zpool import -d "$SCAN_PATH" "$pool" 2>/dev/null; then
        echo "  ✓ Successfully imported '$pool'"
    elif zpool import -d "$SCAN_PATH" -f "$pool" 2>/dev/null; then
        echo "  ✓ Force-imported '$pool' (was previously in use by another system)"
    else
        echo "  ✗ Failed to import '$pool' — pool not found or disks unavailable" >&2
        return 1
    fi
}

verify_mounts() {
    echo
    echo "=== Verifying dataset mounts ==="
    local has_issues=0

    while IFS=$'\t' read -r name mountpoint mounted; do
        if [[ "$mounted" == "yes" ]]; then
            echo "  ✓ $name → $mountpoint"
        else
            echo "  ✗ $name → $mountpoint (NOT MOUNTED)"
            has_issues=1
        fi
    done < <(zfs list -H -o name,mountpoint,mounted 2>/dev/null)

    if [[ $has_issues -eq 1 ]]; then
        echo
        echo "Some datasets are not mounted. Attempting 'zfs mount -a'..."
        zfs mount -a
    fi
}

refresh_cache_and_services() {
    echo
    echo "=== Refreshing ZFS cache and services ==="

    # Regenerate the zpool cache so future boots auto-import
    zpool set cachefile=/etc/zfs/zpool.cache storage-pool 2>/dev/null || true
    zpool set cachefile=/etc/zfs/zpool.cache virt-pool 2>/dev/null || true

    # Ensure ZFS services are enabled for next boot
    systemctl enable zfs-import-cache.service 2>/dev/null || true
    systemctl enable zfs-mount.service 2>/dev/null || true
    systemctl enable zfs-share.service 2>/dev/null || true
    systemctl enable zfs-zed.service 2>/dev/null || true

    echo "  Cache file: /etc/zfs/zpool.cache"
    echo "  ZFS services enabled for next boot."
}


# --- Main ---

if [[ "${1:-}" == "--scan" ]]; then
    scan_pools
fi

echo "=== Importing known pools ==="
failed=0

for pool in "${KNOWN_POOLS[@]}"; do
    import_pool "$pool" || ((failed++))
done

if [[ $failed -gt 0 ]]; then
    echo
    echo "$failed pool(s) could not be imported. Run with --scan to see available pools."
    echo "If disks have moved, you may need to import by GUID or use 'zpool import -d /dev/disk/by-id' manually."
fi

verify_mounts
refresh_cache_and_services

echo
echo "=== Pool status ==="
zpool status -x

echo
echo "Recovery complete. Run 'zpool status' for full details."
