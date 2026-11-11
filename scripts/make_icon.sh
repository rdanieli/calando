#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
if ! { swift package --version >/dev/null 2>&1; } 2>/dev/null && [ -d "$XCODE_DEVELOPER_DIR" ]; then
    export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
fi

WORK="build/icon"
rm -rf "$WORK"
mkdir -p "$WORK/Calando.iconset" Resources docs

swiftc -O scripts/make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$WORK/icon_1024.png" --out "$WORK/Calando.iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$WORK/icon_1024.png" --out "$WORK/Calando.iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$WORK/Calando.iconset" -o Resources/Calando.icns
sips -z 256 256 "$WORK/icon_1024.png" --out docs/icon.png >/dev/null

echo "Icon generated: $ROOT/Resources/Calando.icns"
