#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPOSITORY_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
SHARED_CONFIG_ROOT="$REPOSITORY_ROOT/config"
TEMPLATE_ROOT="$SHARED_CONFIG_ROOT/templates/csharp"
TEMPLATE_PROJECT="$TEMPLATE_ROOT/Jesse.CSharp.Templates.csproj"
COPILOT_INSTRUCTIONS_SOURCE="$SHARED_CONFIG_ROOT/copilot/copilot-instructions.md"
TEMPLATE_PACKAGE_ID="Jesse.CSharp.Templates"
TEMPLATE_SHORT_NAME="jesse-csharp"
MINIMUM_DOTNET_SDK="10.0.400"
NVM_VERSION="v0.40.8"
STAGING_ROOT=""
NVM_INSTALLER=""

cleanup() {
    local temp_root="${TMPDIR:-/tmp}"

    if [[ -n "$STAGING_ROOT" &&
          -d "$STAGING_ROOT" &&
          "$STAGING_ROOT" == "$temp_root"/dotfiles-development.* ]]; then
        rm -rf -- "$STAGING_ROOT"
    fi

    if [[ -n "$NVM_INSTALLER" &&
          -f "$NVM_INSTALLER" &&
          "$NVM_INSTALLER" == "$temp_root"/nvm-install.* ]]; then
        rm -f -- "$NVM_INSTALLER"
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

install_cask_for_command() {
    local cask="$1"
    local command="$2"

    if command -v "$command" &>/dev/null; then
        return
    fi

    brew install --cask "$cask"
}

has_minimum_dotnet_sdk() {
    command -v dotnet &>/dev/null &&
        dotnet --list-sdks |
        awk -v minimum="$MINIMUM_DOTNET_SDK" '
            BEGIN {
                split(minimum, required, ".")
                found = 0
            }
            $1 ~ /^10\./ {
                split($1, actual, ".")
                if (actual[1] > required[1] ||
                    (actual[1] == required[1] && actual[2] > required[2]) ||
                    (actual[1] == required[1] && actual[2] == required[2] && actual[3] >= required[3])) {
                    found = 1
                }
            }
            END {
                exit found ? 0 : 1
            }
        '
}

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this installer supports macOS only." >&2
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target user, not as root." >&2
    exit 1
fi

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew is required. Run bootstrap.sh first." >&2
    exit 1
fi

trap cleanup EXIT

if ! has_minimum_dotnet_sdk; then
    if brew list --cask dotnet-sdk &>/dev/null; then
        brew upgrade --cask dotnet-sdk
    else
        brew install --cask dotnet-sdk
    fi
fi

install_cask_for_command azure-cli az
install_cask_for_command copilot-cli copilot

dotnet --version
az version
copilot --version
pwsh --version
uv --version
git --version
git lfs version
gh --version
mise --version

git lfs install --skip-repo

if [[ ! -f "$COPILOT_INSTRUCTIONS_SOURCE" ]]; then
    echo "ERROR: Copilot instructions not found at $COPILOT_INSTRUCTIONS_SOURCE" >&2
    exit 1
fi

if [[ ! -f "$TEMPLATE_PROJECT" ]]; then
    echo "ERROR: template package project not found at $TEMPLATE_PROJECT" >&2
    exit 1
fi

if ! has_minimum_dotnet_sdk; then
    echo "ERROR: the Jesse C# template requires .NET SDK $MINIMUM_DOTNET_SDK or a later .NET 10 SDK." >&2
    exit 1
fi

copilot_instructions_target="$HOME/.copilot/copilot-instructions.md"

if [[ -e "$copilot_instructions_target" || -L "$copilot_instructions_target" ]]; then
    echo "Personal Copilot instructions already exist at $copilot_instructions_target. Installation skipped."
else
    install -d "$HOME/.copilot"
    install -m 644 \
        "$COPILOT_INSTRUCTIONS_SOURCE" \
        "$copilot_instructions_target"
fi

STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-development.XXXXXX")
package_root="$STAGING_ROOT/packages"
artifacts_root="$STAGING_ROOT/artifacts"
mkdir -p "$package_root"

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
    echo "ERROR: expected one $TEMPLATE_PACKAGE_ID package, found ${#template_packages[@]}." >&2
    exit 1
fi

uninstall_template_package_if_present "CanonicalProject.Templates"
uninstall_template_package_if_present "$TEMPLATE_PACKAGE_ID"

dotnet new install "${template_packages[0]}"
dotnet new "$TEMPLATE_SHORT_NAME" --help >/dev/null

rm -rf -- "$STAGING_ROOT"
STAGING_ROOT=""

NVM_INSTALLER=$(mktemp "${TMPDIR:-/tmp}/nvm-install.XXXXXX")
curl -fsSL \
    "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" \
    -o "$NVM_INSTALLER"

PROFILE=/dev/null NVM_DIR="$HOME/.nvm" bash "$NVM_INSTALLER"
rm -f -- "$NVM_INSTALLER"
NVM_INSTALLER=""

export NVM_DIR="$HOME/.nvm"
# shellcheck source=/dev/null
\. "$NVM_DIR/nvm.sh"

nvm install --lts
nvm alias default 'lts/*'
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

eval "$(mise activate bash)"

mise use --global \
    ruby@latest \
    go@latest

if [[ "$(mise settings get idiomatic_version_file_enable_tools)" != *'"ruby"'* ]]; then
    mise settings add idiomatic_version_file_enable_tools ruby
fi

RUBY_VERSION="$(mise exec -- ruby -e 'print RUBY_VERSION')"
GO_VERSION="$(mise exec -- go env GOVERSION)"
RUBY_BIN="$(mise exec -- ruby -rrubygems -e 'print Gem.bindir')"
GO_BIN="$(mise exec -- go env GOBIN)"

if [[ -z "$RUBY_VERSION" || -z "$GO_VERSION" ]]; then
    echo "ERROR: mise did not activate Ruby and Go." >&2
    exit 1
fi

if [ -z "$GO_BIN" ]; then
    GO_BIN="$(mise exec -- go env GOPATH)/bin"
fi

mkdir -p "$GO_BIN"

mise exec -- gem install --no-document \
    bundler \
    ruby-lsp \
    debug

mise exec -- go install golang.org/x/tools/gopls@latest
mise exec -- go install github.com/go-delve/delve/cmd/dlv@latest
mise exec -- go install honnef.co/go/tools/cmd/staticcheck@latest

for tool in bundle ruby-lsp rdbg; do
    if [ ! -x "${RUBY_BIN}/${tool}" ]; then
        echo "ERROR: Ruby tool was not installed at ${RUBY_BIN}/${tool}" >&2
        exit 1
    fi
done

for tool in gopls dlv staticcheck; do
    if [ ! -x "${GO_BIN}/${tool}" ]; then
        echo "ERROR: Go tool was not installed at ${GO_BIN}/${tool}" >&2
        exit 1
    fi
done

export PATH="$(brew --prefix rustup)/bin:$PATH"

rustup default stable
rustup component add rustfmt clippy rust-analyzer

rustc --version
cargo --version
rust-analyzer --version

echo
echo "Development environment installation completed."
