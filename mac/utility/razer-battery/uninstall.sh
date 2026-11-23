#!/bin/bash

set -euo pipefail

if [ "$#" -ne 0 ]; then
    echo "Usage: bash uninstall.sh" >&2
    exit 2
fi
if [ "$(uname -s)" != "Darwin" ] || [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this uninstaller as the logged-in macOS user, not root." >&2
    exit 1
fi

APPLICATION="$HOME/Applications/RazerBattery.app"
if [ ! -e "$APPLICATION" ] && [ ! -L "$APPLICATION" ]; then
    echo "Razer Battery is not installed."
    exit 0
fi
LOCK_DIR="$HOME/Applications/.razer-battery-install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: another install/uninstall is active, or its lock needs inspection: $LOCK_DIR" >&2
    exit 1
fi
trap 'rmdir "$LOCK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -L "$APPLICATION" ] ||
   [ "$(plutil -extract CFBundleIdentifier raw "$APPLICATION/Contents/Info.plist")" != "com.dotfiles.razer-battery" ]; then
    echo "ERROR: refusing to remove an unrecognized app: $APPLICATION" >&2
    exit 1
fi
codesign --verify --strict "$APPLICATION"
EXECUTABLE="$APPLICATION/Contents/MacOS/razer-battery"
"$EXECUTABLE" --disable-login
"$EXECUTABLE" --quit
rm -rf -- "$APPLICATION"
echo "Removed $APPLICATION and disabled login startup."
