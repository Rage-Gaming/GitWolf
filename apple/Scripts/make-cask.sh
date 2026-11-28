#!/usr/bin/env bash
# Writes the Homebrew cask for a release: Scripts/make-cask.sh 1.2.3 [dir-with-the-release-files] > gitwolf.rb
# The disk image's checksum is read from GitWolf-<version>.sha256 (written by release.sh) next to it.
set -euo pipefail
VERSION="${1:?usage: make-cask.sh VERSION [release-dir]}"
DIR="${2:-$(dirname "$0")/../build/release}"
SUM="$(awk -v f="GitWolf-$VERSION.dmg" '$2 == f {print $1}' "$DIR/GitWolf-$VERSION.sha256")"
[ -n "$SUM" ] || { echo "no checksum for GitWolf-$VERSION.dmg in $DIR/GitWolf-$VERSION.sha256" >&2; exit 1; }
cat <<CASK
cask "gitwolf" do
  version "$VERSION"
  sha256 "$SUM"

  url "https://github.com/ipuppyyt/GitWolf/releases/download/v#{version}/GitWolf-#{version}.dmg"
  name "GitWolf"
  desc "Fast, native Git client"
  homepage "https://ipuppyyt.github.io/GitWolf/"

  livecheck do
    url "https://ipuppyyt.github.io/GitWolf/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "GitWolf.app"

  # GitWolf is signed with its own certificate and not notarised, so macOS would ask once on first launch.
  # Installing through Homebrew is the user's choice to trust it: clear the quarantine flag.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/GitWolf.app"]
  end

  zap trash: [
    "~/Library/Application Support/GitWolf",
    "~/Library/Caches/GitWolf",
    "~/Library/Preferences/org.gitwolf.GitWolf.plist",
  ]
end
CASK
