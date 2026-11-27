# Releasing GitWolf (macOS)

GitWolf updates itself with [Sparkle](https://sparkle-project.org) and costs nothing to run: no Apple
Developer account, no notarisation. Two things make that safe and smooth.

- **Update signature (EdDSA).** Every update archive is signed with a private key only you hold. The app
  carries the matching public key (`SUPublicEDKey` in `Resources/Info.plist`) and refuses an update that
  does not verify. This is what protects users, not Apple's notary.
- **A stable self-signed code-signing certificate** ("GitWolf Release"). Every release is signed with the
  same certificate, so macOS sees the same app after an update and keeps its Keychain access and
  permission grants. (Ad-hoc signatures change on every build and would re-prompt.)

Updates downloaded by the app are not quarantined by macOS, so they open without any Gatekeeper dialog.
Only the **first install** needs the manual step (below).

## How it fits together

| Piece | Where |
| --- | --- |
| Archive the updater downloads (`GitWolf-<v>.zip`), first-install disk image (`.dmg`), `.sha256` | GitHub Release for tag `v<v>` |
| The feed (`appcast.xml`, newest first, last 20 releases) | GitHub Pages, branch `gh-pages`: `https://ipuppyyt.github.io/GitWolf/appcast.xml` |
| Build, sign, package, feed entry | `apple/Scripts/release.sh`, run by `.github/workflows/release.yml` on a `v*` tag |
| Update key tool | `swift run gitwolf-release` (`keys`, `appcast`, `build-number`) |

Sparkle compares the build number (`CFBundleVersion`), which `bundle.sh` derives from the version
(`1.2.3` becomes `1002003`), so versions must be plain `MAJOR.MINOR.PATCH`.

## One-time setup

1. **Update key.** `cd apple && swift run gitwolf-release keys generate` stores a new Ed25519 key in your
   login Keychain and prints the public key. Put the public key in `Resources/Info.plist` as
   `SUPublicEDKey` (already done for the project's key). **Back the private key up**
   (`swift run gitwolf-release keys export key.txt`, keep it in a password manager). If it is lost, installed
   copies can never be updated again and users must reinstall.
2. **Signing certificate.** `cd apple && Scripts/make-signing-cert.sh` creates the "GitWolf Release"
   certificate in your login keychain and writes `build/signing/certificate.p12.base64` and
   `certificate.password`. Back these up too: a different certificate later changes the app's identity, so
   Keychain items and permissions would be asked for once more.
3. **Repository secrets** (Settings > Secrets and variables > Actions):
   `MACOS_CERTIFICATE_P12` (contents of `certificate.p12.base64`), `MACOS_CERTIFICATE_PASSWORD`
   (contents of `certificate.password`), `GITWOLF_UPDATE_KEY` (contents of the exported key file). Delete
   the exported files afterwards (`build/` is git-ignored, but keep them out of backups you do not trust).
4. **GitHub Pages.** After the first release creates the `gh-pages` branch: Settings > Pages > Deploy from a
   branch > `gh-pages` / root.

## Releasing

Update `CHANGELOG.md` (a `## [1.2.3]` section becomes the notes in the update window), then:

```bash
git tag v1.2.3 && git push origin v1.2.3
```

CI tests, signs, publishes the release assets and updates the feed. Running users are offered the update
within a day (or at once through *GitWolf > Check for Updates…*).

Locally: `cd apple && Scripts/release.sh 1.2.3` writes everything to `apple/build/release/`
(`PREVIOUS_APPCAST` and `RELEASE_NOTES` are optional inputs, see the script header). Secrets are never put in
command lines: the update key is read from the Keychain or from `GITWOLF_UPDATE_KEY`, and CI imports the
certificate with `security -i` reading from stdin.

## First install for users (once)

The disk image contains a *Read Me First* note with this. macOS will say it cannot verify GitWolf, because
the app is not notarised:

1. Drag GitWolf to Applications and open it, then click *Done*.
2. System Settings > Privacy & Security > scroll down > *Open Anyway* > confirm.
   Or: `xattr -dr com.apple.quarantine /Applications/GitWolf.app`

After that, updates are installed from inside the app and the step is never repeated.

## Optional: notarisation

If you later get a paid Developer ID, set `SIGN_IDENTITY` to the Developer ID Application identity and
`NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) when running `release.sh`. It then builds with
the hardened runtime and notarises and staples the app and disk image, and the first-install step disappears.
Changing the signing identity once changes the app's identity for existing users, so do it deliberately.

## Version numbers

The version lives only in the tag/argument; `bundle.sh` stamps it into the bundle. Local builds without
`VERSION` keep `0.1.0` from `Resources/Info.plist`. Development builds (no feed in the bundle) say so
when you choose *Check for Updates…* instead of contacting anything.

## App icon

`swift Scripts/make-icon.swift` regenerates `Resources/AppIcon.icns` (flat indigo squircle, white branch
symbol, no gradients).

## For Windows and Linux

Mirror the shape: sign the installer, publish it as a release asset of the same tag, and update in place
(WinSign/MSIX App Installer or Squirrel/Velopack on Windows; AppImageUpdate or Flatpak on Linux).
