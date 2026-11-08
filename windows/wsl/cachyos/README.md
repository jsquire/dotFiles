# CachyOS WSL

### Overview

Included in this section are the artifacts and references used for building and configuring a CachyOS WSL instance as a CLI development environment.  The bootstrap is a single consolidated script that handles system configuration, shell setup, development tooling, and home directory provisioning.

The CachyOS WSL rootfs is sourced from the official [CachyOS WSL image](https://wiki.cachyos.org/virtualization/wsl/). The image creates a sudo-enabled user whose initial shell is Fish. The bootstrap installs the official `cachyos-zsh-config` package, changes the login shell to Zsh, and layers user customizations on top of the CachyOS configuration.

The bootstrap runs in two phases on a new installation. The first phase adds DrvFs metadata support to `/etc/wsl.conf` and exits. Terminate the distribution from PowerShell, launch it again, and rerun the bootstrap. The second phase verifies that metadata is active before configuring Windows-host links or SSH permissions.

### Fresh Installation

The official image requires WSL 2.4.4 or newer. From PowerShell, download and install the latest release:

```powershell
$Version = (
  Invoke-RestMethod https://api.github.com/repos/CachyOS/cachyos-wsl/releases/latest
).tag_name

$Image = Join-Path $env:TEMP "cachyos-$Version.wsl"

Invoke-WebRequest `
  "https://github.com/CachyOS/cachyos-wsl/releases/download/$Version/cachyos-$Version.wsl" `
  -OutFile $Image

wsl --install --from-file $Image
```

Launch the distribution with `wsl -d cachyos` and complete the official first setup. It initializes the package keyring, ranks mirrors, selects the best repository available for the CPU, and creates the default sudo-enabled user.

After first setup:

1. Run `sudo pacman -Syu`.
2. Run `bootstrap.sh`. It updates `/etc/wsl.conf` and exits.
3. From PowerShell, run `wsl --terminate cachyos`.
4. Launch the distribution again and rerun `bootstrap.sh`.
5. Configure the email and signing key placeholders in `home/.gitconfig` before running the bootstrap.
6. Import the GnuPG signing key from secure backup when signed commits are required. The bootstrap creates a native `~/.gnupg` and installs only non-secret configuration.
7. Authenticate GitHub CLI and Copilot through the Linux Secret Service.
8. Enable Docker Desktop integration for `cachyos` when Docker tooling is required.
9. Validate SSH, signed commits, Secret Service, Zed, Zsh, Powerlevel10k, and each development toolchain.

### Development Environments

The bootstrap assigns one version manager to each managed ecosystem.

| Ecosystem | Manager |
| --- | --- |
| Ruby | [mise](https://mise.jdx.dev/) |
| Go | [mise](https://mise.jdx.dev/) |
| Rust | [rustup](https://rustup.rs/) |
| Node | [NVM](https://github.com/nvm-sh/nvm) |
| Python | [uv](https://docs.astral.sh/uv/) |
| .NET | CachyOS packages |

Ruby and Go request `latest` during each bootstrap run.  Mise resolves and installs the current stable releases, then records the resolved versions in its global configuration.  Individual repositories can override them with exact or rolling versions in `mise.toml`.  Ruby projects using `.ruby-version` are also supported.

The Ruby environment includes Bundler, Ruby LSP, and `rdbg`.  The Go environment includes `gopls`, Delve, and Staticcheck.  Rust includes rustfmt, Clippy, and rust-analyzer.

### Secure Storage

The bootstrap installs GNOME Keyring and libsecret to provide the standard
Linux Secret Service used by GitHub Copilot CLI and other development tools.
Its systemd user socket is enabled for the CachyOS WSL session, and available
WSLg display variables are imported so graphical unlock prompts can open. The
first application that stores a credential may ask you to create or unlock the
default keyring.

Older bootstrap versions used `secretsd`. The current bootstrap disables that
service and removes its user-local executable, service definition, D-Bus
activation file, and source checkout after GNOME Keyring successfully answers
on `org.freedesktop.secrets`. Non-empty legacy credential data is preserved and
reported rather than deleted automatically.

#### Using mise

Show the active versions and their configuration sources:

```bash
mise current
mise config ls
```

Select an exact version for a project:

```bash
cd ~/src/example
mise use ruby@4.0.8
mise use go@1.27.3
```

Install versions declared by an existing project:

```bash
mise install
```

Run a command with a temporary version without changing configuration:

```bash
mise exec ruby@3.4.11 -- ruby --version
mise exec go@1.26.4 -- go test ./...
```

Useful official mise references:

* [Getting Started](https://mise.jdx.dev/getting-started.html)
* [Installing and Using Development Tools](https://mise.jdx.dev/dev-tools/)
* [`mise use` Command](https://mise.jdx.dev/cli/use.html)
* [Configuration](https://mise.jdx.dev/configuration.html)
* [Version Selection](https://mise.jdx.dev/dev-tools/versions.html)
* [Configuration Trust](https://mise.jdx.dev/configuration/settings.html#trusted-config-paths)

### Project Storage

Active development repositories belong under `~/src` in the WSL filesystem.  `~/Projects` links to that directory for convenience.  Keeping source and build operations inside WSL avoids cross-filesystem performance and file notification limitations.

Mounted Windows drives remain available under `/mnt`, including the dotFiles checkout used to run the bootstrap.

### Zed

Zed runs on Windows and connects to CachyOS through its native WSL remote support.  The bootstrap links Zed's bundled WSL-aware launcher into `~/.local/bin/zed`, so projects can be opened from CachyOS with:

```bash
zed ~/src
```

The Windows Zed installation and extensions remain managed on Windows.  WSL server settings are copied from `home/.config/zed/settings.json`.  Go and Rust support are built into Zed, while Ruby uses the Ruby extension with Ruby LSP.

### Structure

* **home**  
  _These are the managed `$HOME` items for the active WSL user account, including shell configuration, Git settings, non-secret GnuPG configuration, dircolors, and Zed server settings._

### Items

* **bootstrap.sh**  
  _Authored in 2026, this script bootstraps the CachyOS WSL environment in two restart-safe phases, including system updates, base utilities, modern CLI tools, development platforms, Azure tooling, shell configuration, native WSL project storage, and selected home directory links to the Windows host._
