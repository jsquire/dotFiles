# CachyOS Backup & Restore

Backup and restore scripts for CachyOS using [Kopia](https://kopia.io/) with snapshots stored on the NAS backups export (NFS). Includes automated nightly backups, selective file restore, and full disaster recovery.

## Scripts

| Script | Purpose | When to use |
|--------|---------|-------------|
| `kopia-backup.sh` | One-time setup for nightly backups | First install, or re-establishing after a fresh OS install |
| `kopia-restore.sh` | Browse or restore individual files/directories | "I need to get back a file I deleted" |
| `kopia-restore-full.sh` | Full disaster recovery | "I reinstalled CachyOS and need everything back" |

All scripts require `sudo`.

---

## 1. Initial Configuration

### Prerequisites

- CachyOS installed with `bootstrap.sh` completed (provides `yay`, base packages)
- `nfs-utils` installed (`sudo pacman -S nfs-utils`)
- The NAS backups share exported over NFS and reachable on the LAN (Collaborative/all-squash mode; no uid/gid matching or `no_root_squash` needed)

### Step 1: Run the backup setup script

The script mounts the NAS backups export itself (adds an NFS entry to `/etc/fstab`
with a systemd automount) - no manual mount or samba credentials are required.

```bash
cd ~/src/dotFiles/cachyos/backups
sudo ./kopia-backup.sh
```

It prompts (with defaults) for:

- **NAS host** - the NAS IP (default `192.168.1.100`; an IP is recommended so the mount works before DNS is up at boot).

- **NAS backups NFS export path** - default `/var/nfs/shared/backups`.

- **Local mount point** - default `/mnt/nas-backups`.

- **Repository path** - default `/mnt/nas-backups/Jesse-CachyOS` (this machine's own subfolder on the shared backups export).

- **Backup time** (HH:MM:SS) and a confirmation of the sources and retention policy.

Once complete, the following are configured:

| Component | Location | Purpose |
|-----------|----------|---------|
| Kopia repository | `/mnt/nas-backups/Jesse-CachyOS/` | Snapshot storage on the NAS backups export (NFS) |
| Nightly backup script | `/usr/local/bin/nightly-backup.sh` | Captures manifests + snapshots |
| systemd timer | `nightly-backup.timer` | Fires at 02:00 AM daily |
| Failure notification | KDE notify-send + `~/Desktop/BACKUP_FAILED.txt` | Alerts on failed backup |
| Exclusion rules | `~/.kopiaignore` | Skips caches, Steam, Emulation, etc. |
| Log file | `/var/log/nightly-backup.log` | Backup run output (rotated at 5 MB) |
| Snapper | `snapper-timeline.timer` | Fast btrfs rollback (complements Kopia) |

### Step 2: Verify the setup

```bash
# Confirm the timer is active and see when it fires next
systemctl list-timers | grep nightly

# Confirm kopia can reach the repository
sudo kopia repository status
```

### What gets backed up

Each nightly run captures:

| Source | Contents | Approx Size |
|--------|----------|-------------|
| `/home/jesse` | User data, configs, dotfiles (excludes caches, Steam, Emulation) | ~5-6 GB |
| `/etc` | System configuration | ~15 MB |
| `/boot` | Kernel, initramfs, bootloader | ~200 MB |
| Manifests | Explicit packages, AUR packages, Flatpaks, enabled services, fstab, active mounts | ~50 KB |

Retention policy: **7 daily, 4 weekly, 3 monthly** snapshots. Compression: **zstd**.

---

## 2. Running a Manual Backup

Backups run automatically at 02:00 AM via systemd timer. To run one manually:

```bash
sudo /usr/local/bin/nightly-backup.sh
```

This runs the same sequence as the nightly timer: captures manifests, creates snapshots of `/home`, `/etc`, and `/boot`, then runs repository maintenance.

### Checking backup status

```bash
# See timer status and next scheduled run
systemctl list-timers | grep nightly

# Check the result of the last run
systemctl status nightly-backup.service

# View the full log
cat /var/log/nightly-backup.log

# List all snapshots with dates and sizes
sudo kopia snapshot list
```

If a backup fails, you'll see:
- A KDE desktop notification
- A file on your Desktop: `BACKUP_FAILED.txt` with troubleshooting steps

The failure file is automatically removed on the next successful backup.

---

## 3. Restoring Files (Selective Restore)

Use `kopia-restore.sh` when you need to recover specific files or browse a snapshot.

```bash
cd ~/src/dotFiles/cachyos/backups
sudo ./kopia-restore.sh
```

### What to expect

1. The script lists all available snapshots and their sources (`/home/jesse`, `/etc`, `/boot`)
2. You select which source to restore from
3. You pick a specific snapshot (by manifest ID, or type `latest`)
4. You choose a restore mode:

| Mode | What it does | Use case |
|------|-------------|----------|
| **1. Browse** | FUSE-mounts the snapshot and opens Dolphin | Explore the snapshot, drag-and-drop files out |
| **2. Restore path** | Restores a specific file or directory | Recover `.config/nvim` or `Documents/project` |
| **3. Full restore** | Restores the entire snapshot to its original location | Replace all of `/home/jesse` from a snapshot |

### Examples

**Recover a deleted config directory:**
1. Run `sudo ./kopia-restore.sh`
2. Select the `/home/jesse` source
3. Enter `latest` for the manifest
4. Choose mode `2` (Restore path)
5. Enter `.config/nvim` as the path
6. Accept the default target (`/home/jesse/.config/nvim`)
7. Choose "skip existing" to only restore missing files

**Browse a snapshot to find something:**
1. Run `sudo ./kopia-restore.sh`
2. Select any source, pick a snapshot
3. Choose mode `1` (Browse)
4. Dolphin opens showing the snapshot contents — copy what you need
5. Close Dolphin when done; the mount is automatically cleaned up

### Manual kopia restore commands

If you prefer the command line over the interactive script:

```bash
# List snapshots with manifest IDs
sudo kopia snapshot list /home/jesse --manifest-id

# Restore a specific path from a snapshot
sudo kopia restore kffbb7c28ea6c34d6/.config/nvim /home/jesse/.config/nvim --skip-existing

# FUSE-mount all snapshots for manual browsing
mkdir /tmp/kopia-browse
sudo kopia mount all /tmp/kopia-browse --fuse-allow-other
ls /tmp/kopia-browse/
# When done:
sudo fusermount -u /tmp/kopia-browse
```

---

## 4. Disaster Recovery (Full Restore)

Use `kopia-restore-full.sh` after a fresh CachyOS install to recover your entire system state.

### Before you start

1. Install CachyOS fresh
2. Run `bootstrap.sh` from dotFiles (installs yay, kopia, base packages)
3. Mount the NAS backups export over NFS, e.g. `sudo mkdir -p /mnt/nas-backups && sudo mount -t nfs 192.168.1.100:/var/nfs/shared/backups /mnt/nas-backups` (or run `kopia-backup.sh` first, which adds the persistent mount)
4. Run the disaster recovery script:

```bash
cd ~/src/dotFiles/cachyos/backups
sudo ./kopia-restore-full.sh
```

### What the script does (phase by phase)

**Phase 1 — Package Recovery:**
- Extracts the package manifests from your most recent `/home` backup
- Compares backed-up package lists against what's currently installed
- Shows missing packages and offers to install them (official repos, AUR, and Flatpak)

**Phase 2 — System Configuration (/etc):**
- Restores `/etc` to a staging directory (`/tmp/kopia-restore-staging/etc`)
- Selectively merges only the safe configs back to the live system:
  - ✓ NetworkManager connections (WiFi passwords, VPN configs)
  - ✓ Custom systemd units (not shipped by packages)
  - ✓ Snapper configs
  - ✓ Custom logrotate configs
  - ✓ Samba config
- Skips configs that should come from the fresh install:
  - ✗ machine-id, hostname, locale, timezone
  - ✗ Bootloader configs (grub, systemd-boot)
  - ✗ crypttab, mkinitcpio
  - ✗ passwd, shadow, group (user was created by bootstrap)

**Phase 3 — Home Directory:**
- Restores `/home/jesse` from the latest snapshot
- Choose between skip-existing (safe, recommended) or overwrite-all

**Phase 4 — Boot Partition (optional):**
- Offers to restore `/boot` — usually not needed (the installer sets up the bootloader)

**Phase 5 — Re-establish Backups:**
- Offers to re-run `kopia-backup.sh` to set up the nightly schedule on the new install

### After recovery

1. The staged `/etc` remains at `/tmp/kopia-restore-staging/etc` — browse it for any configs you want to manually merge
2. Reboot to apply all changes
3. Clean up: `sudo rm -rf /tmp/kopia-restore-staging`

---

## 5. Changing Backup Settings

### Re-run setup to change settings

`kopia-backup.sh` is idempotent — re-run it to change the schedule time, repository path, or other settings:

```bash
sudo ./kopia-backup.sh
```

### Modify exclusion rules

Edit `~/.kopiaignore` (one pattern per line, same syntax as `.gitignore`):

```bash
vim ~/.kopiaignore
```

Current exclusions: `.cache/`, `.var/app/*/cache/`, `.vscode/extensions/`, `.rustup/`, `.nvm/versions/`, `.npm/`, `.cargo/registry/`, `.cargo/git/`, `.local/share/Steam/`, `Emulation/`, `.copilot/`, `.local/share/Trash/`

### Adjust retention policy

```bash
sudo kopia policy set /home/jesse --keep-daily=14 --keep-weekly=8 --keep-monthly=6
sudo kopia policy set /etc --keep-daily=14 --keep-weekly=8 --keep-monthly=6
sudo kopia policy set /boot --keep-daily=14 --keep-weekly=8 --keep-monthly=6
```

### Change the backup schedule

Edit the timer directly:

```bash
sudo systemctl edit nightly-backup.timer
```

Override the `OnCalendar` line (e.g., change to 3:30 AM):

```ini
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30:00
```

Then reload: `sudo systemctl daemon-reload`

### View repository info

```bash
sudo kopia repository status
sudo kopia policy show /home/jesse
sudo kopia maintenance info
```
