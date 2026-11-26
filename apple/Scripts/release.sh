#!/usr/bin/env bash
# Builds a signed, notarised, stapled GitSync-<version>.dmg in build/release/.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=gitsync-notary \
#   Scripts/release.sh 1.0.0
#
# One-time setup (credentials stay in your keychain, never in this repo or on a command line):
#   xcrun notarytool store-credentials gitsync-notary --apple-id you@example.com --team-id TEAMID
# (it prompts for an app-specific password). See docs/RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version>, e.g. 1.0.0}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

OUT="build/release"
rm -rf "$OUT"; mkdir -p "$OUT"

VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" Scripts/bundle.sh release
codesign --verify --deep --strict --verbose=2 build/GitSync.app

# Notarise the app (zipped), then staple the ticket to it.
ditto -c -k --keepParent build/GitSync.app "$OUT/GitSync-notarize.zip"
xcrun notarytool submit "$OUT/GitSync-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple build/GitSync.app
rm "$OUT/GitSync-notarize.zip"

# Disk image with an Applications shortcut; sign, notarise and staple it as well.
STAGE="$(mktemp -d)"
cp -R build/GitSync.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/GitSync-$VERSION.dmg"
hdiutil create -volname "GitSync" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

( cd "$OUT" && shasum -a 256 "GitSync-$VERSION.dmg" > "GitSync-$VERSION.dmg.sha256" )
spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
echo "Done: $DMG"
