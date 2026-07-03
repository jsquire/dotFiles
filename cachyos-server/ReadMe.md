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
  _Authored in 2026, this is an idempotent server setup script covering packages, ZSH, KDE Plasma + xrdp, Docker, firewall configuration, Python/uv, Node/NVM, and the NFS client.  Pass `--full` to also mount the NAS Plex media export over NFS and deploy container services end-to-end._

  Arguments:
  | Flag | Default | Purpose |
  |------|---------|---------|
  | `--full` | off | Run the full install (NFS media mount + container services) |
  | `--install-dir PATH` | `/srv/squire-server` | Install location for container services and service data |
  | `--nas-host HOST` | _(none)_ | UNAS Pro hostname/IP that exports the Plex media pool over NFS |
  | `--nas-media-export PATH` | _(none)_ | NFS export path on the NAS for the Plex media (Group 2) pool |
  | `--nas-media-mount PATH` | `/mnt/plex-media` | Local mount point for the NAS media export |

  If `--nas-host`/`--nas-media-export` are omitted, the NFS media mount is skipped (with a warning) and can be added later.

### Storage / NAS

Bulk storage lives on the UNAS Pro, configured through the UniFi Drive web UI (manual; no scripted path):

* **Group 1** — 4× 8TB RAID 5 (or 5× RAID 6 if a fifth drive is added); general files + backups, shared via SMB to Windows clients.
* **Group 2** — 2× 3TB RAID 1; Plex media library, exported over NFS to this server.

The NAS NFS export's uid/gid must match the Plex container's `PLEX_UID`/`PLEX_GID` (written into `container-services/.env`) so Plex can read the media.

### Post-Install Manual Steps

1. Configure the UNAS Pro: create the RAID groups, the SMB shares (Group 1), and the NFS export (Group 2, allowed to this server's IP, uid/gid matched to Plex).
2. Copy existing Plex media onto the NAS Group 2 pool before first Plex start.
3. If the external backup drive wasn't mounted during bootstrap, mount it and re-run `bootstrap.sh` to complete Kopia setup.
4. First container start (if not using `--full`): `cd <install-dir>/container-services && ./start-services.sh` (generates `.env` with secrets).

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
3. Configure the NAS (RAID groups, SMB shares, NFS export) and note its IP + export path
4. Run `bootstrap.sh --full --nas-host <ip> --nas-media-export <path>`
5. Manual steps above
