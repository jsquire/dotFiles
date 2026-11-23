#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR="${1:-$SCRIPT_DIR/dist}"

if [ "$#" -gt 1 ]; then
    echo "Usage: bash build.sh [output-directory]" >&2
    exit 2
fi
if [ "$(uname -s)" != "Darwin" ]; then
    echo "ERROR: this utility builds on macOS only." >&2
    exit 1
fi
if ! xcode-select -p &>/dev/null; then
    echo "ERROR: install Xcode Command Line Tools before building." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P)
WORK_DIR=$(mktemp -d "$OUTPUT_DIR/.razer-build.XXXXXX")
APP_DIR="$WORK_DIR/RazerBattery.app"
DESTINATION="$OUTPUT_DIR/RazerBattery.app"
cleanup() {
    local status=$?
    if [ -e "$WORK_DIR/previous.app" ] && [ ! -e "$DESTINATION" ]; then
        mv "$WORK_DIR/previous.app" "$DESTINATION"
    fi
    rm -rf -- "$WORK_DIR"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [ -e "$DESTINATION" ] || [ -L "$DESTINATION" ]; then
    if [ -L "$DESTINATION" ] ||
       [ "$(plutil -extract CFBundleIdentifier raw "$DESTINATION/Contents/Info.plist")" != "com.dotfiles.razer-battery" ]; then
        echo "ERROR: refusing to replace an unrecognized app: $DESTINATION" >&2
        exit 1
    fi
fi
mkdir -p "$APP_DIR/Contents/MacOS" "$WORK_DIR/.module-cache"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
    -fmodules-cache-path="$WORK_DIR/.module-cache" \
    -c "$SCRIPT_DIR/Sources/USBControlReader.m" -o "$WORK_DIR/USBControlReader.o"
xcrun swiftc \
    -swift-version 6 -O -warnings-as-errors \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$WORK_DIR/.module-cache" \
    -framework AppKit -framework IOKit -framework IOUSBHost -framework ServiceManagement \
    -import-objc-header "$SCRIPT_DIR/Sources/USBControlReader.h" \
    "$WORK_DIR/USBControlReader.o" \
    "$SCRIPT_DIR"/Sources/*.swift \
    -o "$APP_DIR/Contents/MacOS/razer-battery"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
codesign --force --sign - "$APP_DIR"
codesign --verify --strict "$APP_DIR"
if [ -e "$DESTINATION" ]; then
    mv "$DESTINATION" "$WORK_DIR/previous.app"
fi
mv "$APP_DIR" "$DESTINATION"
echo "Built $DESTINATION"
