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

if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${SIGN_IDENTITY:-}" ] || [ "$SIGN_IDENTITY" = "-" ]; then
        echo "NOTARY_PROFILE requires SIGN_IDENTITY set to a Developer ID Application identity" >&2
        exit 64
    fi
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

hdiutil verify "$DMG"
shasum -a 256 "$DMG"

echo "Installer ready: $ROOT/$DMG"
