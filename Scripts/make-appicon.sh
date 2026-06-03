#!/usr/bin/env bash
# Regenerate assets/AppIcon.icns from assets/AppIcon-1024.png.
# The .icns is what macOS shows for the .app, in the DMG, Spotlight, Raycast, etc.
# (CFBundleIconFile=AppIcon in Resources/Info.plist; copied into the bundle by the Makefile.)
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/AppIcon-1024.png"
OUT="assets/AppIcon.icns"
ICONSET="$(mktemp -d)/AppIcon.iconset"

[ -f "$SRC" ] || { echo "✗ missing $SRC" >&2; exit 1; }

mkdir -p "$ICONSET"

# size  filename
gen() { sips -z "$1" "$1" "$SRC" --out "$ICONSET/$2" >/dev/null; }

gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
gen 1024 icon_512x512@2x.png

iconutil --convert icns --output "$OUT" "$ICONSET"
rm -rf "$(dirname "$ICONSET")"
echo "✓ wrote $OUT"
