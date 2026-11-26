#!/usr/bin/env bash
# Builds GitSync and wraps it in build/GitSync.app (ad-hoc signed, for local use).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/GitSync"

APP="build/GitSync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GitSync"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Translations: every Resources/<lang>.lproj folder (see Scripts/extract-strings.py).
for lproj in Resources/*.lproj; do [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"; done
codesign --force --sign - "$APP"
echo "Built $APP"
