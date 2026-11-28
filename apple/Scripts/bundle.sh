#!/usr/bin/env bash
# Builds GitWolf and wraps it in build/GitWolf.app, with the Sparkle updater framework inside.
#
#   Scripts/bundle.sh [release|debug]
#
# Environment:
#   VERSION         marketing version to stamp into Info.plist (e.g. 1.0.0); also sets the build number
#   SIGN_IDENTITY   codesign identity: "-" (ad hoc, the default), a self-signed certificate name such as
#                   "GitWolf Release" (see Scripts/make-signing-cert.sh), or a Developer ID Application identity
#   SIGN_KEYCHAIN   keychain that holds the identity (default: the search list)
#   HARDENED=1      add the hardened runtime (needed for notarisation; only with a Developer ID)
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-release}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
IDENTITY="${SIGN_IDENTITY:--}"

swift build -c "$CONFIG" --product GitWolf
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/GitWolf"

APP="build/GitWolf.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/GitWolf"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Scripts/gitwolf "$APP/Contents/Resources/gitwolf"
# Translations: every Resources/<lang>.lproj folder (see Scripts/extract-strings.py).
for lproj in Resources/*.lproj; do [ -d "$lproj" ] && cp -R "$lproj" "$APP/Contents/Resources/"; done

if [ -n "${VERSION:-}" ]; then
  BUILD="$(swift run -c "$CONFIG" gitwolf-release build-number "$VERSION")"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

# Sparkle: copy the framework next to the app and let the executable find it there.
SPARKLE="$(find .build/artifacts -type d -name Sparkle.framework -path '*macos*' | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework not found; run swift build first" >&2; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/GitWolf" 2>/dev/null || true

# Sign inside-out: Sparkle's helpers, the framework, then the app, all with the same identity.
OPTS=(--force --sign "$IDENTITY")
if [ -n "${SIGN_KEYCHAIN:-}" ]; then OPTS+=(--keychain "$SIGN_KEYCHAIN"); fi
if [ "${HARDENED:-}" = "1" ]; then OPTS+=(--options runtime --timestamp); fi
SP="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$SP"/Versions/B/XPCServices/*.xpc "$SP/Versions/B/Autoupdate" "$SP/Versions/B/Updater.app" "$SP"; do
  [ -e "$item" ] && codesign "${OPTS[@]}" "$item"
done
if [ "${HARDENED:-}" = "1" ]; then
  codesign "${OPTS[@]}" --entitlements Resources/GitWolf.entitlements "$APP"
else
  codesign "${OPTS[@]}" "$APP"
fi
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed as: $IDENTITY)"
