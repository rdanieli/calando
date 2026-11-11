#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP="build/Calando.app"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

if ! { swift package --version >/dev/null 2>&1; } 2>/dev/null && [ -d "$XCODE_DEVELOPER_DIR" ]; then
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/Calando" "$APP/Contents/MacOS/Calando"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/Calando.icns "$APP/Contents/Resources/Calando.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

plutil -lint "$APP/Contents/Info.plist"

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --deep --sign - --entitlements Calando.entitlements "$APP"
else
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements Calando.entitlements "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "Bundle ready: $ROOT/$APP"
