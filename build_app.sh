#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="build/Fader.app"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if ! { swift package --version >/dev/null 2>&1; } 2>/dev/null && [ -d "$XCODE_DEVELOPER_DIR" ]; then
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Fader" "$APP/Contents/MacOS/Fader"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Fader.icns "$APP/Contents/Resources/Fader.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist"

codesign --force --deep --sign - --entitlements Fader.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Bundle pronto: $ROOT/$APP"
