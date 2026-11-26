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
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Translations: every Resources/<lang>.lproj folder (see Scripts/extract-strings.py).
for lproj in Resources/*.lproj; do [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"; done
if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# Ad-hoc signed by default. Scripts/release.sh signs with a Developer ID instead (SIGN_IDENTITY).
if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/GitSync.entitlements --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
