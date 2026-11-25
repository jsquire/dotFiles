#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_DIR="${1:-$SCRIPT_DIR/dist/tests}"

if [ "$#" -gt 2 ] || { [ "$#" -eq 2 ] && [ "$2" != "--ui" ]; }; then
    echo "Usage: bash test.sh [output-directory] [--ui]" >&2
    exit 2
fi
if [ "$(uname -s)" != "Darwin" ] || ! xcode-select -p &>/dev/null; then
    echo "ERROR: macOS and installed Xcode Command Line Tools are required." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR=$(cd -- "$OUTPUT_DIR" && pwd -P)
WORK_DIR=$(mktemp -d "$OUTPUT_DIR/.razer-test.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$WORK_DIR/.module-cache"
xcrun clang -fobjc-arc -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.0 \
    -fmodules-cache-path="$WORK_DIR/.module-cache" \
    -c "$SCRIPT_DIR/Sources/USBControlReader.m" -o "$WORK_DIR/USBControlReader.o"
xcrun swiftc \
    -swift-version 6 -warnings-as-errors \
    -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$WORK_DIR/.module-cache" \
    -framework AppKit -framework IOKit -framework IOUSBHost -framework ServiceManagement \
    -import-objc-header "$SCRIPT_DIR/Sources/USBControlReader.h" \
    "$WORK_DIR/USBControlReader.o" \
    "$SCRIPT_DIR/Sources/LoginStartup.swift" \
    "$SCRIPT_DIR/Sources/BatteryProtocol.swift" \
    "$SCRIPT_DIR/Sources/BatteryPolling.swift" \
    "$SCRIPT_DIR/Sources/BatteryReader.swift" \
    "$SCRIPT_DIR/Sources/MenuBarApp.swift" \
    "$SCRIPT_DIR/Tests/main.swift" \
    -o "$WORK_DIR/razer-battery-tests"
if [ "$#" -eq 2 ]; then
    "$WORK_DIR/razer-battery-tests" --ui
else
    "$WORK_DIR/razer-battery-tests"
fi
