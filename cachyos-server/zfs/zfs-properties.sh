#!/usr/bin/env bash

set -euo pipefail

readonly SCRUB_SERVICE_PATH="/etc/systemd/system/zfs-monthly-scrub.service"
readonly SCRUB_TIMER_PATH="/etc/systemd/system/zfs-monthly-scrub.timer"
readonly -a ZFS_SERVICES=(
  zfs-import-cache.service
  zfs-mount.service
  zfs-share.service
  zfs-zed.service
)
readonly -a POOLS=(storage-pool virt-pool)

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
  fi
}

pool_exists() {
  zpool list -H -o name "$1" >/dev/null 2>&1
}

dataset_exists() {
  zfs list -H -o name "$1" >/dev/null 2>&1
}

ensure_pool_properties() {
  local pool="$1"

  if pool_exists "$pool"; then
    echo "Applying properties to ${pool}"
    zfs set \
      compression=lz4 \
      atime=off \
      xattr=sa \
      acltype=posixacl \
      "$pool"
  else
    echo "Skipping missing pool: ${pool}" >&2
  fi
}

ensure_dataset() {
  local pool="$1"
  local dataset="$2"
  local mountpoint="$3"

  if ! pool_exists "$pool"; then
    echo "Skipping dataset ${dataset}; pool ${pool} is missing" >&2
    return
  fi

  if dataset_exists "$dataset"; then
    echo "Ensuring mountpoint for existing dataset ${dataset}"
    zfs set mountpoint="$mountpoint" "$dataset"
  else
    echo "Creating dataset ${dataset}"
    zfs create -o mountpoint="$mountpoint" "$dataset"
  fi
}

install_scrub_units() {
  install -d -m 0755 /etc/systemd/system

  cat >"${SCRUB_SERVICE_PATH}" <<'EOF_SERVICE'
[Unit]
Description=Run monthly ZFS scrub across configured pools
After=zfs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/bash -lc 'for pool in storage-pool virt-pool; do if /usr/bin/zpool list -H -o name "$pool" >/dev/null 2>&1; then /usr/bin/zpool scrub "$pool"; fi; done'
EOF_SERVICE

  cat >"${SCRUB_TIMER_PATH}" <<'EOF_TIMER'
[Unit]
Description=Run ZFS scrub on the second Sunday of every month

[Timer]
OnCalendar=Sun *-*-08..14 03:00:00
Persistent=true
AccuracySec=1h
Unit=zfs-monthly-scrub.service

[Install]
WantedBy=timers.target
EOF_TIMER

  systemctl daemon-reload
  systemctl enable --now zfs-monthly-scrub.timer
}

enable_zfs_services() {
  systemctl enable --now "${ZFS_SERVICES[@]}"
}

main() {
  require_root

  for pool in "${POOLS[@]}"; do
    ensure_pool_properties "$pool"
  done

  ensure_dataset storage-pool storage-pool/storage /storage
  ensure_dataset storage-pool storage-pool/data /data
  ensure_dataset virt-pool virt-pool/virtualization /virtualization

  install_scrub_units
  enable_zfs_services
}

main "$@"
