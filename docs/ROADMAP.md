# Roadmap

## Next
- Translations: strings are extracted (`apple/Scripts/extract-strings.py`), no language is shipped yet; interpolated strings need hand-made keys
- Notarised releases (optional): needs a paid Apple Developer ID. The free path (self-signed certificate, Sparkle updates, Homebrew cask) is live; see [RELEASING.md](RELEASING.md)
- Finder status badges and desktop widgets (need app extensions, so an Xcode project), Spotlight and Shortcuts actions

## Later
- Git LFS download/lock actions (needs git-lfs), a bisect run script
- Bundled OAuth client IDs for github.com, gitlab.com, codeberg.org and Azure DevOps (Bitbucket Cloud can't ship one: it needs a secret)
- Formal reviews and assignees on pull requests; issues for Bitbucket and Azure DevOps
- Windows and Linux native clients (see [PORTING.md](PORTING.md))
