#!/usr/bin/env bash
#
# REFERENCE ONLY - DO NOT RUN BLINDLY.
#
# This file documents the ZFS layout used on the current server.
# Pool creation is destructive and will erase data on the specified devices.
# Review every command, replace all /dev/disk/by-id/ placeholders, and confirm
# the target disks before running anything manually.
#
# ashift guidance:
#   - Use ashift=12 for 4K sector drives (recommended default for most disks)
#   - Use ashift=13 for 8K sector drives if your hardware requires it
#
# Pool-level filesystem properties used on both pools:
#   compression=lz4
#   atime=off
#   xattr=sa
#   acltype=posixacl

# -----------------------------------------------------------------------------
# storage-pool
#   layout: raidz1
#   disks:  4x 7.3T HDDs
#   cache:  nvme0n1p3 (250G L2ARC)
# -----------------------------------------------------------------------------

# Example create command (replace every placeholder by-id path first):
zpool create \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  storage-pool raidz1 \
  /dev/disk/by-id/REPLACE_STORAGE_DISK_1 \
  /dev/disk/by-id/REPLACE_STORAGE_DISK_2 \
  /dev/disk/by-id/REPLACE_STORAGE_DISK_3 \
  /dev/disk/by-id/REPLACE_STORAGE_DISK_4 \
  cache /dev/disk/by-id/REPLACE_STORAGE_L2ARC

# Datasets:
zfs create -o mountpoint=/storage storage-pool/storage
zfs create -o mountpoint=/data storage-pool/data

# -----------------------------------------------------------------------------
# virt-pool
#   layout: mirror
#   disks:  2x 2.7T HDDs
#   cache:  nvme0n1p4 (108.7G L2ARC)
# -----------------------------------------------------------------------------

# Example create command (replace every placeholder by-id path first):
zpool create \
  -o ashift=12 \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  virt-pool mirror \
  /dev/disk/by-id/REPLACE_VIRT_DISK_1 \
  /dev/disk/by-id/REPLACE_VIRT_DISK_2 \
  cache /dev/disk/by-id/REPLACE_VIRT_L2ARC

# Dataset:
zfs create -o mountpoint=/virtualization virt-pool/virtualization

# -----------------------------------------------------------------------------
# Importing existing pools on new hardware
# -----------------------------------------------------------------------------

# Scan by-id paths, then import by pool name:
zpool import -d /dev/disk/by-id storage-pool
zpool import -d /dev/disk/by-id virt-pool

# If you want to inspect pools before importing:
zpool import -d /dev/disk/by-id

# After importing existing pools, re-apply documented properties and datasets
# with ./zfs-properties.sh if needed.
