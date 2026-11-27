# Releasing GitSync (macOS)

A release is a signed, notarised, stapled `GitSync-<version>.dmg` attached to a GitHub release. The
app's *Check for Updates…* command (and a once-a-day background check, switchable in Settings) asks
GitHub's public releases API (`UpdateChecker` in core) for the latest non-draft, non-pre-release tag,
compares it with the app's `CFBundleShortVersionString`, and offers to open the release page. It never
downloads or installs anything itself, so there is no update feed or signing key to protect; a
Sparkle-style in-place updater would be a separate, later decision.

## What you need (one time)

1. An Apple Developer Program membership and a **Developer ID Application** certificate in your login
   keychain (Xcode > Settings > Accounts > Manage Certificates, or developer.apple.com).
2. Notarisation credentials stored in the keychain, not in files or on a command line:
   `xcrun notarytool store-credentials gitsync-notary --apple-id <you> --team-id <TEAMID>`
   (it prompts for an app-specific password), or use an App Store Connect API key with `--key`.

## Local release

```bash
cd apple
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=gitsync-notary \
Scripts/release.sh 1.0.0
```

`Scripts/release.sh` builds a release binary, wraps it with `Scripts/bundle.sh` (icon, `Info.plist`,
`*.lproj`, version stamped from the argument), signs it with the hardened runtime and
`Resources/GitSync.entitlements`, submits it to Apple's notary service, staples the ticket, builds a
disk image, signs/notarises/staples that too, and writes a `.sha256` next to it. The app is **not**
sandboxed: GitSync runs the system `git` and opens arbitrary folders.

## Release from CI

`.github/workflows/release.yml` does the same when a `v*` tag is pushed, using repository secrets
(certificate `.p12`, its password, the signing identity name, and an App Store Connect API key). Secrets
are never put in command lines (`security -i` reads from stdin) or written to the repo. This workflow has
not been run yet: expect to debug it on the first tag, ideally with a `v0.0.0-test` tag on a fork.

## Version numbers

The version lives only in the tag/argument; `bundle.sh` stamps it into the bundle. Local builds without
`VERSION` keep `0.1.0` from `Resources/Info.plist`. Tags must look like `v1.2.3`; pre-release suffixes
(`v1.2.3-beta.1`) are ignored by the update check.

## App icon

`swift Scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` (flat indigo squircle, white branch
symbol, no gradients).

## For Windows and Linux

Mirror the shape: sign the installer (Authenticode / a GPG-signed AppImage or Flatpak), publish it as a
release asset of the same tag, and use `UpdateChecker`'s contract (`/releases/latest`, tag compared as
a version, only an `https://github.com/...` page is ever opened).
