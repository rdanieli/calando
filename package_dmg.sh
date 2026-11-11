#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

./build_app.sh

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
STAGING="build/dmg"
DMG="build/Fader-$VERSION.dmg"

rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R build/Fader.app "$STAGING/Fader.app"
ln -s /Applications "$STAGING/Applications"

diskutil image create from --format UDZO --volumeName "Fader" "$STAGING" "$DMG"
hdiutil verify "$DMG"
shasum -a 256 "$DMG"

echo "Instalador pronto: $ROOT/$DMG"
