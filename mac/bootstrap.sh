#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_HOMEBREW=false
INSTALL_APPLICATIONS=true
INSTALL_DEVELOPMENT=true
INSTALL_SHELL=true
RUN_PACKAGE_MAINTENANCE=false
FORCE_CONFIGURATION=false

usage() {
    cat <<'EOF'
Usage: bootstrap.sh [options]

Options:
  --install-homebrew       Install Homebrew when it is not already available.
  --skip-applications      Skip graphical application installation.
  --skip-development       Skip language runtimes and development tooling.
  --skip-shell             Skip shell and editor configuration deployment.
  --force                  Replace modified managed configuration files.
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
        --force)
            FORCE_CONFIGURATION=true
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

if [ "$INSTALL_APPLICATIONS" = true ]; then
    macos_version=$(sw_vers -productVersion)
    macos_major_version=${macos_version%%.*}

    if ! [[ "$macos_major_version" =~ ^[0-9]+$ ]] ||
       [ "$macos_major_version" -lt 15 ]; then
        echo "ERROR: installing the managed applications requires macOS 15 or later because of Windows App." >&2
        exit 1
    fi
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

install_mas_application() {
    local application="$1"
    local app_store_id="$2"

    if application_exists "$application"; then
        echo "$application is already installed. Mac App Store installation skipped."
        return
    fi

    echo "Installing $application from the Mac App Store. Sign-in or authentication may be required."
    mas get "$app_store_id"

    if ! application_exists "$application"; then
        echo "ERROR: Mac App Store reported success, but $application was not found." >&2
        return 1
    fi
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

register_linearmouse_login() {
    local application

    if [ -d "/Applications/LinearMouse.app" ]; then
        application="/Applications/LinearMouse.app"
    elif [ -d "$HOME/Applications/LinearMouse.app" ]; then
        application="$HOME/Applications/LinearMouse.app"
    else
        echo "ERROR: LinearMouse.app was not found for login registration." >&2
        return 1
    fi

    if ! osascript - "$application" <<'APPLESCRIPT'
on run argv
    set appPath to item 1 of argv
    tell application "System Events"
        repeat with existingItem in login items
            if path of existingItem is appPath then return
            if name of existingItem is "LinearMouse" or name of existingItem is "LinearMouse.app" then
                error "An existing LinearMouse login item points to a different path."
            end if
        end repeat
        make login item at end with properties {path:appPath, hidden:false}
        repeat with existingItem in login items
            if path of existingItem is appPath then return
        end repeat
        error "LinearMouse login item was not registered."
    end tell
end run
APPLESCRIPT
    then
        echo "ERROR: could not register LinearMouse at login. Allow System Events automation or add it in System Settings, then retry." >&2
        return 1
    fi
}

brew bundle --file="$SCRIPT_DIR/Brewfile"

if [ "$INSTALL_APPLICATIONS" = true ]; then
    install_font
    install_application ghostty "Ghostty.app"
    install_application 1password "1Password.app"
    install_application linearmouse "LinearMouse.app"
    install_application karabiner-elements "Karabiner-Elements.app"
    install_application visual-studio-code "Visual Studio Code.app"
    install_application zed "Zed.app"
    install_application microsoft-edge "Microsoft Edge.app"
    install_application onedrive "OneDrive.app"
    install_application slack "Slack.app"
    install_application windows-app "Windows App.app"
    install_microsoft_office
    bash "$SCRIPT_DIR/install-write-md.sh"
    install_mas_application "Xcode.app" "497799835"

    input_args=()
    if [ "$FORCE_CONFIGURATION" = true ]; then
        input_args+=(--force)
    fi
    bash "$SCRIPT_DIR/install-input-config.sh" "${input_args[@]}"
    register_linearmouse_login

    echo "Opening Karabiner-Elements to set up its background services."
    if [ -d "/Applications/Karabiner-Elements.app" ]; then
        open "/Applications/Karabiner-Elements.app"
    elif [ -d "$HOME/Applications/Karabiner-Elements.app" ]; then
        open "$HOME/Applications/Karabiner-Elements.app"
    else
        echo "ERROR: Karabiner-Elements.app was not found." >&2
        exit 1
    fi
    echo "ACTION REQUIRED: complete Karabiner-Elements permissions setup and enable the desired rules."
    echo "Allow its background services in System Settings so it starts at login."
fi

if [ "$INSTALL_SHELL" = true ]; then
    shell_args=()

    if [ "$FORCE_CONFIGURATION" = true ]; then
        shell_args+=(--force)
    fi

    DOTFILES_DEFER_SSH_ACTION=true \
        bash "$SCRIPT_DIR/init-shell.sh" "${shell_args[@]}"
fi

if [ "$INSTALL_DEVELOPMENT" = true ]; then
    bash "$SCRIPT_DIR/install-development.sh"
fi

if [ "$RUN_PACKAGE_MAINTENANCE" = true ]; then
    brew cleanup
fi

echo
echo "macOS bootstrap completed."

if [ "$INSTALL_SHELL" = true ]; then
    echo
    echo "ACTION REQUIRED: run this yourself in a normal local Terminal, not through Copilot or SSH:"
    printf '  SSH_AUTH_SOCK="$(/bin/launchctl getenv SSH_AUTH_SOCK)" /usr/bin/ssh-add --apple-use-keychain %q\n' \
        "$HOME/.ssh/github_signing"
    echo "Then log out and back in once to activate automatic local login loading."
fi
