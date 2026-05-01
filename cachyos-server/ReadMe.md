# CachyOS Server

### Overview

Included in this section are the artifacts and references used for building and configuring a CachyOS-based multi-purpose home server.  The environment focuses on file sharing (Samba), media serving (Plex), DNS ad-blocking (Pi-hole + Cloudflared), containerized services, and ZFS-backed storage using a raidz1 pool for bulk storage and a mirror pool for services.  

In some cases, the artifacts may be a subset of functionality, requiring use in a specific way or order to be helpful, where others may be a fully automated and self-contained process.  Please remember that these were written for practical personal use and are not intended to be examples of best practice, nor polished and production-ready.

### Shared Resources

These resources from the base `cachyos/` directory are directly compatible with the server environment and should be used as-is rather than duplicated here.

| Resource | Purpose | Notes |
|----------|---------|-------|
| `cachyos/backups/kopia-backup.sh` | Nightly backup setup | Prompts for paths; add `/virtualization` as source |
| `cachyos/backups/kopia-restore.sh` | Selective file restore | Works as-is |
| `cachyos/backups/kopia-restore-full.sh` | Disaster recovery | Works as-is |
| `cachyos/secureboot.sh` | Secure Boot setup | Only if hardware is UEFI + Limine |

### Structure

* **home**  
  _Based on `cachyos/home`, this contains the $HOME items for the user account, including zsh, git, and gpg-agent configuration adapted for the server environment with `EDITOR=nano` and curses pinentry._

* **container-services**  
  _Docker Compose services and operational scripts for the server-hosted containers._

* **samba**  
  _Samba file share configuration for the server._

* **zfs**  
  _ZFS pool creation reference, properties configuration, and pool recovery script for use after OS upgrades._

### Items

* **bootstrap.sh**  
  _Authored in 2026, this is an idempotent server setup script covering packages, ZSH, KDE Plasma + xrdp, ZFS, Samba, Docker, firewall configuration, Python/uv, and Node/NVM.  Pass `--full` to also recover ZFS pools and deploy container services end-to-end._

### Post-Install Manual Steps

1. Create Samba user passwords: `sudo smbpasswd -a jesse`, etc.
2. Configure Kopia backups: run `../cachyos/backups/kopia-backup.sh`
3. First container start (if not using `--full`): `cd /virtualization/container-services && ./start-services.sh` (generates `.env` with secrets)

### Execution Order

**Minimal install** (base system, no containers):

1. Install CachyOS (KDE Plasma edition)
2. (Optional) Run `../cachyos/secureboot.sh` if UEFI
3. Run `bootstrap.sh`
4. Import/create ZFS pools (`sudo zfs/recover-pools.sh` or manual `zfs/create-pools.sh`)
5. Deploy containers manually via `container-services/install-services.sh`
6. Manual steps above

**Full install** (end-to-end):

1. Install CachyOS (KDE Plasma edition)
2. (Optional) Run `../cachyos/secureboot.sh` if UEFI
3. Run `bootstrap.sh --full`
4. Manual steps above
