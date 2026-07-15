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

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mkdir -p "$HELPER/Contents/MacOS"

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
