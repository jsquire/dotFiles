# CachyOS WSL

### Overview

Included in this section are the artifacts and references used for building and configuring a CachyOS WSL instance as a CLI development environment.  The bootstrap is a single consolidated script that handles system configuration, shell setup, development tooling, and home directory provisioning.

The CachyOS WSL rootfs is sourced from [okrc/CachyOS-WSL](https://github.com/okrc/CachyOS-WSL) and ships with a pre-configured ZSH environment via `cachyos-zsh-config`.  The bootstrap layers user customizations on top of that base rather than replacing it.

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
  _These are the $HOME items for the ZSH profile associated with the active WSL user account, including shell configuration, Git settings, GPG agent configuration, dircolors, and Zed server settings._

### Items

* **bootstrap.sh**  
  _Authored in 2026, this script automates the full bootstrapping of the CachyOS WSL environment in a single pass, including system updates, base utilities, modern CLI tools, development platforms, Azure tooling, shell configuration, native WSL project storage, and selected home directory links to the Windows host._
