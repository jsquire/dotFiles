# macOS

### Overview

This directory contains a public, general-purpose macOS workstation bootstrap.
It installs cross-platform applications and command-line development tools,
then adds shell and editor configuration. Files changed after deployment are
preserved unless replacement is explicitly requested.

The scripts target macOS 14 or later. Running the Applications phase requires
macOS 15 or later because Windows App does not support earlier releases.
Homebrew casks enforce any other stricter application requirements.

### Usage

Install Xcode Command Line Tools before running the bootstrap.

```bash
xcode-select --install
```

Run the bootstrap from this directory in a complete dotFiles repository clone.
Homebrew is reused when present.

```bash
bash ./bootstrap.sh
```

Allow the script to install Homebrew when it is absent.

```bash
bash ./bootstrap.sh --install-homebrew
```

Optional phases can be skipped independently.

```bash
bash ./bootstrap.sh \
    --skip-applications \
    --skip-development \
    --skip-shell
```

Homebrew cleanup is opt-in.

```bash
bash ./bootstrap.sh --package-maintenance
```

Replace locally modified managed configuration files.

```bash
bash ./bootstrap.sh --force
```

### Applications

The bootstrap installs these public vendor applications when they are not
already present.

* Ghostty
* 1Password
* LinearMouse
* Microsoft Edge
* Microsoft 365
* OneDrive
* Slack
* Visual Studio Code
* Windows App
* Write.md
* Xcode
* Zed

Existing application bundles are preserved regardless of whether they were
installed manually, by Homebrew, or by device-management software.

Xcode is installed from the Mac App Store and requires an Apple Account signed
in there; macOS may also request authentication and administrator approval.
Windows App requires macOS 15 or later. Write.md is pinned to a signed and
notarized Apple silicon release, with its published SHA-256 checked before
installation. Update the version and checksum in
`install-write-md.sh` when adopting a new release.

Ghostty 1.3 or later includes a supported menu action for becoming the default
terminal application. After installation, select **Ghostty > Set Ghostty as
Default Terminal App**.

Zed is configured for local editing with client telemetry and AI disabled.
Signing in and enabling hosted services remain manual decisions.

### Development Environments

The development installer assigns one manager to each managed ecosystem.

| Ecosystem | Manager |
| --- | --- |
| Ruby | [mise](https://mise.jdx.dev/) |
| Go | [mise](https://mise.jdx.dev/) |
| Rust | [rustup](https://rustup.rs/) |
| Node | [NVM](https://github.com/nvm-sh/nvm) |
| Python | [uv](https://docs.astral.sh/uv/) |
| .NET 11 | [.NET SDK](https://dotnet.microsoft.com/download) |

Ruby and Go request `latest` during each installer run. Node installs the latest
LTS release and makes it the default. Rust uses the stable toolchain.

The Ruby environment includes Bundler, Ruby LSP, and `rdbg`. The Go environment
includes `gopls`, Delve, and Staticcheck. Rust includes rustfmt, Clippy, and
rust-analyzer.

The installer also provides Azure CLI, GitHub CLI, Git LFS, GitHub Copilot CLI,
PowerShell, uv, common build tools, and the shared C# project template.

### Shell Configuration

The tracked `.zprofile` and `.zshrc` are small loaders for configuration under
`~/.config/dotfiles`. On an existing machine, `init-shell.sh` appends the
loader only when it is missing.

Managed files are tracked in `~/.config/dotfiles/install-state.tsv`. Files that
still match the last deployed version receive repository updates automatically.
Locally modified files are preserved unless `--force` is used, and replacements
receive timestamped backups.

The shell uses zsh, Oh My Zsh, the shared Powerlevel10k configuration, and
Caskaydia Mono Nerd Font. NVM is initialized before mise to match the other
tracked environments.

The same Jesse color palette, font, and window dimensions are installed as an
Apple Terminal profile and selected as its default. Unmodified installed
profiles receive tracked updates. GnuPG uses Homebrew's pinentry while
preserving the configured agent cache duration for non-Git OpenPGP operations.

An existing modified `.gitconfig` is preserved unless `--force` is used. A
fresh installation receives a template with an email placeholder and the
standard shared SSH signing-key path.

### SSH Signing

The SSH identity is restored separately and is not stored in this repository.
Restore these files under `~/.ssh` before running `init-shell.sh`:

* `github_signing`
* `github_signing.pub`
* `allowed_signers`

The script applies modes `600`, `640`, and `640`, installs a noninteractive
per-user login job, and ends with a manual action. Run that command yourself in
a normal local Terminal, never through Copilot or SSH:

```bash
SSH_AUTH_SOCK="$(/bin/launchctl getenv SSH_AUTH_SOCK)" /usr/bin/ssh-add --apple-use-keychain ~/.ssh/github_signing
```

This one-time manual step stores the passphrase in the login Keychain without
exposing it to the installer or an AI-controlled process. Log out and back in
once afterward. The `com.jessesquire.github-signing` LaunchAgent then runs at
local GUI login and loads only `github_signing` from Keychain. It pins
`SSH_AUTH_SOCK` to the launchd-owned local socket, refuses remote SSH sessions,
refuses execution outside its launchd parent, disables askpass, has no terminal
input, and logs a nonsecret message instead of prompting if loading fails.

Git commits and tags use SSH signing. The public key must be registered with
GitHub as a signing key, and `allowed_signers` must associate the Git commit
email with that public key. Existing personalized Git configuration is
migrated by changing only signing-related settings.

### Structure

* **Brewfile**  
  _Declares command-line packages managed through Homebrew._

* **bootstrap.sh**  
  _Orchestrates Homebrew, public applications, development tooling, and shell
  configuration._

* **install-development.sh**  
  _Installs language runtimes, language tooling, cloud tooling, Copilot CLI,
  and shared development assets._

* **init-shell.sh**  
  _Deploys additive shell, SSH-based Git signing, GnuPG, Ghostty, Terminal,
  Zed, and Powerlevel10k configuration with timestamped backups. SSH identity
  files remain outside this repository._

* **home**  
  _Contains portable user configuration and macOS-specific terminal settings._

* **utility**  
  _Contains independently built macOS utilities, including the native Razer
  battery menu-bar monitor. These are not installed by the bootstrap._

Organization-specific enrollment, authentication, security controls, and
internal documentation are intentionally outside this public repository.
