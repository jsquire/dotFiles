#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_HOMEBREW=false
INSTALL_APPLICATIONS=true
INSTALL_DEVELOPMENT=true
INSTALL_SHELL=true
RUN_PACKAGE_MAINTENANCE=false

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

Options:
  --install-homebrew       Install Homebrew when it is not already available.
  --skip-applications      Skip graphical application installation.
  --skip-development       Skip language runtimes and development tooling.
  --skip-shell             Skip shell and editor configuration deployment.
  --package-maintenance    Run Homebrew cleanup after installation.
  -h, --help               Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-homebrew)
            INSTALL_HOMEBREW=true
            ;;
        --skip-applications)
            INSTALL_APPLICATIONS=false
            ;;
        --skip-development)
            INSTALL_DEVELOPMENT=false
            ;;
        --skip-shell)
            INSTALL_SHELL=false
            ;;
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

if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this bootstrap supports macOS only." >&2
    exit 1
fi

if [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this script as the target user, not as root." >&2
    exit 1
fi

if ! xcode-select -p &>/dev/null; then
    echo "ERROR: Xcode Command Line Tools are required." >&2
    echo "Run 'xcode-select --install', complete the installer, then retry." >&2
    exit 1
fi

configure_homebrew() {
    if command -v brew &>/dev/null; then
        return
    fi

    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
}

install_homebrew() {
    local installer
    local status

    installer=$(mktemp "${TMPDIR:-/tmp}/homebrew-install.XXXXXX")

    curl -fsSL \
        https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
        -o "$installer" || {
            status=$?
            rm -f -- "$installer"
            return "$status"
        }

    /bin/bash "$installer" || {
        status=$?
        rm -f -- "$installer"
        return "$status"
    }

    rm -f -- "$installer"
}

configure_homebrew

if ! command -v brew &>/dev/null; then
    if [ "$INSTALL_HOMEBREW" = false ]; then
        echo "ERROR: Homebrew is not available." >&2
        echo "Retry with --install-homebrew or install Homebrew separately." >&2
        exit 1
    fi

    install_homebrew
    configure_homebrew
fi

if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew installation completed but brew is unavailable." >&2
    exit 1
fi

application_exists() {
    local application="$1"

    [ -d "/Applications/$application" ] ||
        [ -d "$HOME/Applications/$application" ]
}

install_application() {
    local cask="$1"
    local application="$2"

    if application_exists "$application"; then
        echo "$application is already installed. Homebrew installation skipped."
        return
    fi

    if brew list --cask "$cask" &>/dev/null; then
        echo "$cask is already managed by Homebrew."
        return
    fi

    brew install --cask "$cask"
}

install_font() {
    if compgen -G "$HOME/Library/Fonts/Caskaydia*Mono*Nerd*" >/dev/null ||
       brew list --cask font-caskaydia-mono-nerd-font &>/dev/null; then
        echo "Caskaydia Mono Nerd Font is already installed."
        return
    fi

    brew install --cask font-caskaydia-mono-nerd-font
}

install_microsoft_office() {
    if application_exists "Microsoft Word.app" &&
       application_exists "Microsoft Excel.app" &&
       application_exists "Microsoft PowerPoint.app"; then
        echo "Microsoft Office is already installed. Homebrew installation skipped."
        return
    fi

    if brew list --cask microsoft-office &>/dev/null; then
        echo "microsoft-office is already managed by Homebrew."
        return
    fi

    brew install --cask microsoft-office
}

brew bundle --file="$SCRIPT_DIR/Brewfile"

if [ "$INSTALL_APPLICATIONS" = true ]; then
    install_font
    install_application ghostty "Ghostty.app"
    install_application visual-studio-code "Visual Studio Code.app"
    install_application zed "Zed.app"
    install_application microsoft-edge "Microsoft Edge.app"
    install_application onedrive "OneDrive.app"
    install_application slack "Slack.app"
    install_microsoft_office
fi

if [ "$INSTALL_SHELL" = true ]; then
    bash "$SCRIPT_DIR/init-shell.sh"
fi

if [ "$INSTALL_DEVELOPMENT" = true ]; then
    bash "$SCRIPT_DIR/install-development.sh"
fi

if [ "$RUN_PACKAGE_MAINTENANCE" = true ]; then
    brew cleanup
fi

echo
echo "macOS bootstrap completed."
