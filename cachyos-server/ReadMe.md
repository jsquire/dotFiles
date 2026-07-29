# CachyOS Server

# CachyOS Server

### Overview

Included in this section are the artifacts and references used for building and configuring a CachyOS-based multi-purpose home server.  The environment focuses on media serving (Plex), DNS ad-blocking with encrypted upstreams (AdGuard Home with DNS-over-HTTPS), and containerized services.  Bulk storage and SMB file sharing are handled by a separate Ubiquiti UNAS Pro NAS; the server consumes the NAS Plex media pool over NFS.  Container services and their data live on the local host drive under a configurable install location.

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Shared Resources

These resources from the base `cachyos/` directory are directly compatible with the server environment and should be used as-is rather than duplicated here.

| Resource | Purpose | Notes |
|----------|---------|-------|
| `cachyos/secureboot.sh` | Secure Boot setup | Only if hardware is UEFI + Limine |

### Structure

* **home**  
  _Based on `cachyos/home`, this contains the $HOME items for the user account, including zsh, git, and gpg-agent configuration adapted for the server environment with `EDITOR=nano` and curses pinentry._

* **container-services**  
  _Docker Compose services and operational scripts for the server-hosted containers (AdGuard Home, Plex)._

### Items

* **bootstrap.sh**  
  _Authored in 2026, this is an idempotent server setup script covering packages, ZSH, KDE Plasma + KRDP (KDE's built-in Remote Desktop), Docker, firewall configuration, Python/uv, Node/NVM, and the NFS client.  Pass `--full` to also mount the NAS Plex media export over NFS and deploy container services end-to-end._

  Arguments:
  | Flag | Default | Purpose |
  |------|---------|---------|
  | `--full` | off | Run the full install (NFS media mount + container services) |
  | `--install-dir PATH` | `/srv/squire-server` | Install location for container services and service data |
  | `--nas-host HOST` | _(none)_ | UNAS Pro hostname/IP that exports the Plex media pool over NFS |
  | `--nas-media-export PATH` | _(none)_ | NFS export path on the NAS for the Plex media (Group 2) pool |
  | `--nas-media-mount PATH` | `/mnt/plex-media` | Local mount point for the NAS media export |
  | `--nas-backup-export PATH` | _(none)_ | NFS export path on the NAS for the Kopia backup repo |
  | `--nas-backup-mount PATH` | `/mnt/nas-backups` | Local mount point for the NAS backup export |
  | `--maintenance-schedule CAL` | `Sat *-*-* 00:00:00` | `OnCalendar` expression for the automated maintenance window |

  If `--nas-host`/`--nas-media-export` are omitted, the NFS media mount is skipped (with a warning) and can be added later.  Likewise, if `--nas-host`/`--nas-backup-export` are omitted, the NAS backup mount and Kopia repo setup are skipped and can be added later.

### Storage / NAS

Bulk storage lives on the UNAS Pro, configured through the UniFi Drive web UI (manual; no scripted path):

* **Group 1** — 4× 8TB RAID 5 (or 5× RAID 6 if a fifth drive is added); general files + backups, shared via SMB to Windows clients and exported over NFS to this server for the Kopia backup repo.
* **Group 2** — 2× 3TB RAID 1; Plex media library, exported over NFS to this server.

Both shares use the NAS's **Collaborative (all-squash)** mode, which maps every client to the share's owner. As a result, Plex reads media regardless of `PLEX_UID`/`PLEX_GID`, and Kopia (running as root) can write the backup repo without `no_root_squash`. Collaborative mode also keeps the shares reachable over SMB (Windows clients) and NFS (this server) simultaneously.

### Automated Maintenance

`bootstrap.sh` installs a single weekly maintenance job, `squire-server-maintenance.timer`, which runs at **Saturday 00:00** by default and must finish before the 02:00 Kopia backup.  It is one merged unit rather than several timers: because every step runs sequentially in one script, the steps cannot overlap or race each other, and containers are guaranteed to restart *after* the packages they depend on have been updated.

Steps, in order:

1. `pacman -Syu` against the official repositories.
2. `yay -Syu` for AUR packages, run as the dedicated `aurbuild` system account.
3. `restart-update.sh` to pull and restart the containers (unchanged; it is simply invoked from here now).
4. Cleanup: remove orphaned packages, then trim the package cache with `paccache -rk3` and `paccache -ruk0`.
5. Report unmerged `.pacnew`/`.pacsave` config files.
6. Reboot **only if** the running kernel's modules directory has disappeared or a core package (`linux*`, `systemd`, `glibc`, `dbus`, `nvidia*`) changed.

Notes on the design:

* **`aurbuild` account.**  `yay` refuses to run as root and shells out to `sudo pacman`, so unattended AUR updates need a non-root account with a narrow grant.  `bootstrap.sh` creates the `aurbuild` system user and installs `/etc/sudoers.d/aurbuild` (`NOPASSWD: /usr/bin/pacman`), validated with `visudo -cf` before it is put in place.  The interactive user's sudo rules are not modified.  Note the practical consequence: package *install* still happens as root and install scriptlets run as root, so this narrows the build phase, not the blast radius.
* **Reboot safety.**  The job refuses to reboot if `sshd` is not active, since SSH is the only remote recovery path (there is no autologin, and KRDP exists only inside a logged-in session).  Cleanup deliberately runs *before* the reboot, because a reboot terminates the script.
* **Missed runs are skipped, not caught up** (`Persistent=false`), so an update and possible reboot can never fire unexpectedly in the middle of the day.  The trade-off is that a missed Saturday means a two-week gap.
* **Bounded runtime.**  `TimeoutStartSec=5400` caps the run at 90 minutes, guaranteeing it cannot reach the 02:00 backup window regardless of how long an AUR build takes.
* **Failure reporting.**  There is no SMTP server available to this host, so failures are surfaced locally: `/var/lib/squire-maintenance/last-run-failed` records the timestamp, failing step, exit status and a consecutive-failure count, and `/etc/profile.d/squire-maintenance-banner.sh` prints a banner on every interactive login until a successful run clears it.  Visibility is therefore only as timely as the next login.  A run that reboots and never comes back cannot be reported by this mechanism.
* **Config drift reporting.**  Config files are never merged automatically, since a bad merge could break DNS, boot, or pacman itself.  Instead the job counts `.pacnew`/`.pacsave` files under `/etc` each run.  If the count has *risen* since the previous run, `/var/lib/squire-maintenance/pacnew-increased` is written and the same login banner reports it in yellow, listing the unmerged files.  The marker clears itself on the next run where the count does not rise, so the banner reports *newly appeared* files rather than nagging about a standing backlog you have deliberately left alone.  Review with `sudo pacdiff`, or dismiss without merging via `sudo rm -f /var/lib/squire-maintenance/pacnew-increased`.
* **Logs.**  `/var/log/squire-maintenance.log`, rotated by `/etc/logrotate.d/squire-maintenance`.
* **Recovery.**  `snap-pac` takes a pre/post snapshot on every pacman transaction.  Prefer fixing forward; if that is impractical, `snapper -c root list` then `snapper -c root rollback <N>`, or pick a snapshot from the Limine boot menu if the machine will not boot.

Useful commands:

```bash
systemctl list-timers squire-server-maintenance.timer
systemctl status squire-server-maintenance.service
sudo systemctl start squire-server-maintenance.service   # run now, supervised
sudo tail -f /var/log/squire-maintenance.log
pacdiff --output                                         # list unmerged config files
```

### Post-Install Manual Steps

1. Configure the UNAS Pro: create the RAID groups and enable NFS (Collaborative/all-squash) on the media (Group 2) and backups (Group 1) shares, allowed to this server's IP. No uid/gid matching is required under all-squash.
2. Copy existing Plex media onto the NAS Group 2 pool before first Plex start.
3. If `--nas-backup-export` wasn't provided during bootstrap, re-run `bootstrap.sh` with `--nas-host` and `--nas-backup-export` to mount the NAS backups export and complete Kopia setup.
4. First container start (if not using `--full`): `cd <install-dir>/container-services && ./start-services.sh` (generates `.env` with secrets).
5. Resolve any unmerged config files with `sudo pacdiff` (`pacdiff --output` lists them).  `pacman` writes a `.pacnew` whenever a config file it tracks was changed both locally and upstream, so it never silently discards a local edit.  Keeping this list empty is what makes the maintenance job's drift report meaningful.

### Execution Order

**Minimal install** (base system, no containers):

1. Install CachyOS (KDE Plasma edition)
2. (Optional) Run `../cachyos/secureboot.sh` if UEFI
3. Run `bootstrap.sh`
4. Deploy containers manually via `container-services/install-services.sh <install-dir>/container-services <install-dir>/adguard`
5. Manual steps above

**Full install** (end-to-end):

1. Install CachyOS (KDE Plasma edition)
2. (Optional) Run `../cachyos/secureboot.sh` if UEFI
3. Configure the NAS (RAID groups, SMB shares, NFS exports for media + backups) and note its IP + export paths
4. Run `bootstrap.sh --full --nas-host <ip> --nas-media-export <media-path> --nas-backup-export <backups-path>`
5. Manual steps above
