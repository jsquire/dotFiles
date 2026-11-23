#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENABLE_LOGIN=false
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--enable-login" ]; }; then
    echo "Usage: bash install.sh [--enable-login]" >&2
    exit 2
fi
if [ "$#" -eq 1 ]; then ENABLE_LOGIN=true; fi
if [ "$(uname -s)" != "Darwin" ] || [ "$EUID" -eq 0 ]; then
    echo "ERROR: run this installer as the logged-in macOS user, not root." >&2
    exit 1
fi

APPLICATIONS="$HOME/Applications"
DESTINATION="$APPLICATIONS/RazerBattery.app"
EXECUTABLE="$DESTINATION/Contents/MacOS/razer-battery"
PREVIOUS_LOGIN=not-registered
PREVIOUS_RUNNING=false
PREVIOUS_STOPPED=false
COMMITTED=false
mkdir -p "$APPLICATIONS"
LOCK_DIR="$APPLICATIONS/.razer-battery-install.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "ERROR: another install/uninstall is active, or its lock needs inspection: $LOCK_DIR" >&2
    exit 1
fi
WORK_DIR=""
cleanup() {
    local status=$?
    if [ -n "$WORK_DIR" ] && [ "$COMMITTED" = false ] && [ -d "$WORK_DIR/previous.app" ]; then
        if [ -e "$DESTINATION" ]; then
            mv "$DESTINATION" "$WORK_DIR/failed.app"
        fi
        mv "$WORK_DIR/previous.app" "$DESTINATION"
        if [ "$PREVIOUS_LOGIN" = enabled ]; then
            "$EXECUTABLE" --enable-login || echo "ERROR: restore login startup manually." >&2
        fi
    fi
    if [ "$COMMITTED" = false ] && [ "$PREVIOUS_STOPPED" = true ] &&
       [ "$PREVIOUS_RUNNING" = true ] && [ -d "$DESTINATION" ]; then
        open "$DESTINATION"
    fi
    if [ -n "$WORK_DIR" ]; then rm -rf -- "$WORK_DIR"; fi
    rmdir "$LOCK_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
WORK_DIR=$(mktemp -d "$APPLICATIONS/.razer-install.XXXXXX")

if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    if [ -L "$DESTINATION" ] ||
       [ "$(plutil -extract CFBundleIdentifier raw "$DESTINATION/Contents/Info.plist")" != "com.dotfiles.razer-battery" ]; then
        echo "ERROR: refusing to replace an unrecognized app: $DESTINATION" >&2
        exit 1
    fi
    codesign --verify --strict "$DESTINATION"
    PREVIOUS_LOGIN=$("$EXECUTABLE" --login-status)
    if "$EXECUTABLE" --running; then PREVIOUS_RUNNING=true; fi
fi

bash "$SCRIPT_DIR/build.sh" "$WORK_DIR/build"
codesign --verify --strict "$WORK_DIR/build/RazerBattery.app"
if [ -e "$DESTINATION" ]; then
    "$EXECUTABLE" --quit
    PREVIOUS_STOPPED=true
    mv "$DESTINATION" "$WORK_DIR/previous.app"
fi
mv "$WORK_DIR/build/RazerBattery.app" "$DESTINATION"
codesign --verify --strict "$DESTINATION"
COMMITTED=true

if [ "$ENABLE_LOGIN" = true ] || [ "$PREVIOUS_LOGIN" = enabled ]; then
    "$EXECUTABLE" --enable-login
fi
open "$DESTINATION"
for ((attempt = 0; attempt < 50; attempt++)); do
    if "$EXECUTABLE" --running; then
        echo "Installed and running: $DESTINATION"
        echo "Launch at login: $("$EXECUTABLE" --login-status)"
        exit 0
    fi
    sleep 0.1
done
echo "ERROR: installed application did not remain running." >&2
exit 1
