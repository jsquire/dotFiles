#!/bin/bash

set -euo pipefail

RUN_PACKAGE_MAINTENANCE=false
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SHARED_CONFIG_ROOT="$REPOSITORY_ROOT/config"
TEMPLATE_ROOT="$SHARED_CONFIG_ROOT/templates/csharp"
TEMPLATE_PROJECT="$TEMPLATE_ROOT/Jesse.CSharp.Templates.csproj"
COPILOT_INSTRUCTIONS_SOURCE="$SHARED_CONFIG_ROOT/copilot/copilot-instructions.md"
TEMPLATE_PACKAGE_ID="Jesse.CSharp.Templates"
TEMPLATE_SHORT_NAME="jesse-csharp"
MINIMUM_DOTNET_SDK="10.0.400"
STAGING_ROOT=""

usage() {
    cat <<'EOF'
Usage: install-development.sh [options]

Options:
  --package-maintenance  Remove orphaned dependencies and prune package caches.
  -h, --help             Show this help.
EOF
}

cleanup() {
    local temp_root="${TMPDIR:-/tmp}"

    if [[ -n "$STAGING_ROOT" &&
          -d "$STAGING_ROOT" &&
          "$STAGING_ROOT" == "$temp_root"/dotfiles-development.* ]]; then
        rm -rf -- "$STAGING_ROOT"
    fi
}

uninstall_template_package_if_present() {
    local package_id="$1"
    local output
    local status

    if output=$(dotnet new uninstall "$package_id" 2>&1); then
        printf '%s\n' "$output"
    else
        status=$?

        if [[ $status -ne 103 ]]; then
            printf '%s\n' "$output" >&2
            return "$status"
        fi
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --package-maintenance)
            RUN_PACKAGE_MAINTENANCE=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target desktop user, not as root." >&2
    exit 1
fi

trap cleanup EXIT

############################################
# Version Targets
############################################



############################################
# System Update
############################################

sudo pacman -Syu --noconfirm


############################################
# Install .NET SDK (CachyOS / Arch Repo)
############################################

sudo pacman -S --needed --noconfirm \
    dotnet-sdk \
    dotnet-runtime \
    aspnet-runtime

# Verify install
dotnet --version
dotnet --list-sdks


############################################
# Install Azure CLI
############################################

sudo pacman -S --needed --noconfirm azure-cli


############################################
# Install GitHub Copilot CLI
############################################

# Installed from the official repo (github-copilot-cli) so it lands in /usr/bin
# and is managed by pacman, rather than the user-local wget installer.
sudo pacman -S --needed --noconfirm github-copilot-cli


############################################
# Install Shared Development Configuration
############################################

if [[ ! -f "$COPILOT_INSTRUCTIONS_SOURCE" ]]; then
    echo "Copilot instructions not found at $COPILOT_INSTRUCTIONS_SOURCE" >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE_PROJECT" ]]; then
    echo "Template package project not found at $TEMPLATE_PROJECT" >&2
    exit 1
fi

latest_dotnet_10=$(
    dotnet --list-sdks |
        awk '$1 ~ /^10\./ { print $1 }' |
        sort -V |
        tail -n 1
)

if [[ -z "$latest_dotnet_10" ||
      "$(printf '%s\n%s\n' "$MINIMUM_DOTNET_SDK" "$latest_dotnet_10" | sort -V | head -n 1)" != "$MINIMUM_DOTNET_SDK" ]]; then
    echo "The Jesse C# template requires .NET SDK $MINIMUM_DOTNET_SDK or a later .NET 10 SDK." >&2
    exit 1
fi

copilot_instructions_target="$HOME/.copilot/copilot-instructions.md"

if [[ -e "$copilot_instructions_target" || -L "$copilot_instructions_target" ]]; then
    echo "Personal Copilot instructions already exist at $copilot_instructions_target. Installation skipped."
else
    echo "Installing personal Copilot instructions..."
    install -Dm644 \
        "$COPILOT_INSTRUCTIONS_SOURCE" \
        "$copilot_instructions_target"
fi

STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-development.XXXXXX")
package_root="$STAGING_ROOT/packages"
artifacts_root="$STAGING_ROOT/artifacts"
mkdir -p "$package_root"

echo "Packing $TEMPLATE_PACKAGE_ID..."
dotnet pack \
    "$TEMPLATE_PROJECT" \
    --configuration Release \
    --artifacts-path "$artifacts_root" \
    --output "$package_root" \
    --nologo

shopt -s nullglob
template_packages=("$package_root"/"$TEMPLATE_PACKAGE_ID".*.nupkg)
shopt -u nullglob

if [[ ${#template_packages[@]} -ne 1 ]]; then
    echo "Expected one $TEMPLATE_PACKAGE_ID package, found ${#template_packages[@]}." >&2
    exit 1
fi

uninstall_template_package_if_present "CanonicalProject.Templates"
uninstall_template_package_if_present "$TEMPLATE_PACKAGE_ID"

echo "Installing $(basename "${template_packages[0]}")..."
dotnet new install "${template_packages[0]}"
dotnet new "$TEMPLATE_SHORT_NAME" --help >/dev/null

rm -rf -- "$STAGING_ROOT"
STAGING_ROOT=""


############################################
# Install Node Version Manager (NVM)
############################################

# Installed from the official repositories rather than a pinned curl installer,
# so pacman -Syu keeps it current. The package ships /usr/share/nvm/init-nvm.sh,
# which sets NVM_DIR (~/.nvm here, since XDG_CONFIG_HOME is unset) and sources
# nvm plus completions.

sudo pacman -S --needed --noconfirm nvm

# Legacy ~/.nvm installs from the old curl installer leave real files where the
# package expects to place symlinks, so init-nvm.sh silently keeps loading the
# stale copy. Report it once; installed node versions under ~/.nvm/versions are
# unaffected and are reused by the packaged nvm.

if [ -f "$HOME/.nvm/nvm.sh" ] && [ ! -L "$HOME/.nvm/nvm.sh" ]; then
    echo
    echo "NOTE: a legacy curl-installed nvm is present in ~/.nvm and will shadow"
    echo "      the packaged one (/usr/share/nvm). Your installed node versions in"
    echo "      ~/.nvm/versions are NOT affected and will be reused."
    echo "      One-time cleanup, then this notice stops appearing:"
    echo "        rm -rf ~/.nvm/nvm.sh ~/.nvm/nvm-exec ~/.nvm/bash_completion \\"
    echo "               ~/.nvm/.git ~/.nvm/*.md ~/.nvm/Dockerfile ~/.nvm/test"
    echo "      Then open a new shell and confirm with: nvm --version"
    echo
fi

# Source NVM for this session
# shellcheck source=/dev/null
[ -s /usr/share/nvm/init-nvm.sh ] && \. /usr/share/nvm/init-nvm.sh


############################################
# Install Node + Global Tooling
############################################

# Install latest Node LTS if no default set
if ! nvm which default &>/dev/null; then
    nvm install --lts
    nvm alias default 'lts/*'
fi

nvm use default

npm install -g npm

npm install -g \
    typescript \
    @babel/cli \
    @babel/core \
    eslint \
    nyc \
    webpack-cli \
    webpack

############################################
# Install Zed Editor (AUR)
############################################

yay -S --needed --noconfirm zed-preview-bin


############################################
# Install Rust Toolchain
############################################

# rustup conflicts with system rust package - remove it first if present
if pacman -Qi rust &>/dev/null; then
    echo "Removing system rust package (conflicts with rustup)..."
    sudo pacman -Rns --noconfirm rust 2>/dev/null || true
fi

sudo pacman -S --needed --noconfirm \
    rustup \
    clang \
    lldb \
    pkg-config \
    openssl

# Install and set stable toolchain as default
# rustup default is idempotent - safe to run multiple times
rustup default stable
rustup component add rustfmt clippy 2>/dev/null || true

# Verify
rustc --version
cargo --version


############################################
# Additional Dev Tools
############################################

sudo pacman -S --needed --noconfirm \
    python \
    python-pip \
    python-virtualenv \
    jq \
    yq \
    httpie \
    cmake \
    meson \
    ninja


############################################
# Optional package maintenance
############################################

if [ "$RUN_PACKAGE_MAINTENANCE" = true ]; then
    ORPHANS=$(pacman -Qtdq || true)

    if [ -n "$ORPHANS" ]; then
        sudo pacman -Rns --noconfirm $ORPHANS
    fi

    if command -v paccache &>/dev/null; then
        sudo paccache -r
    else
        sudo pacman -Sc --noconfirm
    fi
fi
