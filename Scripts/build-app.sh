#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/Scripts/swift-env.sh"

swift build \
    --disable-sandbox \
    --scratch-path "$ROOT/.build" \
    --configuration release \
    --product CodexPulseApp
swift build \
    --disable-sandbox \
    --scratch-path "$ROOT/.build" \
    --configuration release \
    --product CodexPulseMonitor

BIN_DIR="$(swift build --disable-sandbox --scratch-path "$ROOT/.build" --configuration release --show-bin-path)"
APP="$ROOT/dist/Codex Pulse.app"
HELPER="$APP/Contents/Library/LoginItems/CodexPulseMonitor.app"
ICONSET="$ROOT/.build/CodexPulse.iconset"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$HELPER/Contents/MacOS"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
while read -r filename size; do
    sips -z "$size" "$size" "$ROOT/assets/weekly-codex-icon.png" \
        --out "$ICONSET/$filename" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES
swift "$ROOT/Scripts/make-icns.swift" \
    "$ICONSET" "$APP/Contents/Resources/CodexPulse.icns"
rm -rf "$ICONSET"

cp "$BIN_DIR/CodexPulseApp" "$APP/Contents/MacOS/CodexPulseApp"
cp "$ROOT/Packaging/CodexPulse-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/assets/weekly-codex-icon.png" "$APP/Contents/Resources/weekly-codex-icon.png"

cp "$BIN_DIR/CodexPulseMonitor" "$HELPER/Contents/MacOS/CodexPulseMonitor"
cp "$ROOT/Packaging/CodexPulseMonitor-Info.plist" "$HELPER/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist"
codesign --force --sign - "$HELPER"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP"
