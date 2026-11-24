#!/bin/bash

set -euo pipefail

APPLICATION="Write.md.app"
DESTINATION="$HOME/Applications/$APPLICATION"
VERSION="1.0.1"
SHA256="2cb7cb50f558b95fbebf0fe55cc39a57f599ddfcb88147bc407b514f05689203"
DOWNLOAD_URL="https://github.com/danielbilek/writemd/releases/download/v$VERSION/Write.md-$VERSION-arm64.dmg"

if [ -d "/Applications/$APPLICATION" ] || [ -d "$DESTINATION" ]; then
    echo "Write.md is already installed."
    exit 0
fi

if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: Write.md currently provides macOS builds for Apple silicon only." >&2
    exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/writemd.XXXXXX")
STAGING_DIR=""
MOUNTED=false
MOUNT_POINT="$WORK_DIR/mount"

cleanup() {
    local status=$?
    trap - EXIT

    if [ "$MOUNTED" = true ]; then
        if ! hdiutil detach "$MOUNT_POINT" -quiet; then
            echo "ERROR: failed to detach the Write.md disk image." >&2
            status=1
        fi
    fi

    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        if ! rm -rf -- "$STAGING_DIR"; then
            echo "ERROR: failed to remove the temporary Write.md staging directory." >&2
            status=1
        fi
    fi

    if [ -d "$WORK_DIR" ] && ! rm -rf -- "$WORK_DIR"; then
        echo "ERROR: failed to remove the temporary Write.md download directory." >&2
        status=1
    fi

    exit "$status"
}
trap cleanup EXIT

mkdir -p "$MOUNT_POINT" "$HOME/Applications"
DMG_PATH="$WORK_DIR/Write.md.dmg"

curl -fL --retry 3 "$DOWNLOAD_URL" -o "$DMG_PATH"
printf '%s  %s\n' "$SHA256" "$DMG_PATH" | shasum -a 256 -c -

hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MOUNT_POINT" "$DMG_PATH"
MOUNTED=true

SOURCE_APP="$MOUNT_POINT/$APPLICATION"
if [ ! -d "$SOURCE_APP" ]; then
    echo "ERROR: the verified Write.md disk image does not contain $APPLICATION." >&2
    exit 1
fi

STAGING_DIR=$(mktemp -d "$HOME/Applications/.writemd.XXXXXX")
STAGED_APP="$STAGING_DIR/$APPLICATION"
ditto "$SOURCE_APP" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
spctl --assess --type execute --verbose=2 "$STAGED_APP"

if [ -d "/Applications/$APPLICATION" ] || [ -d "$DESTINATION" ]; then
    echo "Write.md was installed while this bootstrap was running; keeping the existing app."
    exit 0
fi

mv "$STAGED_APP" "$DESTINATION"
echo "Installed Write.md to $DESTINATION."
