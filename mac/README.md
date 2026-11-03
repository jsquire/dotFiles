# macOS

### Overview

This directory contains a public, general-purpose macOS workstation bootstrap.
It installs cross-platform applications and command-line development tools,
then adds shell and editor configuration. Files changed after deployment are
preserved unless replacement is explicitly requested.

The scripts target macOS 14 or later. Homebrew casks enforce any stricter
application requirements.

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
* Microsoft Edge
* Microsoft 365
* OneDrive
* Slack
* Visual Studio Code
* Zed

Existing application bundles are preserved regardless of whether they were
installed manually, by Homebrew, or by device-management software.

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
| .NET | [.NET SDK](https://dotnet.microsoft.com/download) |

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
preserving the configured agent cache duration.

An existing modified `.gitconfig` is preserved unless `--force` is used. A
fresh installation receives a template with identity and signing-key
placeholders that must be configured before signed commits will work.

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
  _Deploys additive shell, Git, GnuPG, Ghostty, Terminal, Zed, and Powerlevel10k
  configuration with timestamped backups._

* **home**  
  _Contains portable user configuration and macOS-specific terminal settings._

Organization-specific enrollment, authentication, security controls, and
internal documentation are intentionally outside this public repository.
