# Roadmap

## Next
- First notarised release: needs an Apple Developer ID; tooling and CI workflow exist but have not been run (see [RELEASING.md](RELEASING.md))
- Translations: strings are extracted (`apple/Scripts/extract-strings.py`), no language is shipped yet; interpolated strings need hand-made keys
- In-place auto-update (Sparkle-style); today the app only announces new releases
- A menu bar extra (status item) in addition to the Dock badge and menu

## Later
- Git LFS download/lock actions (needs git-lfs), a bisect run script
- Bundled OAuth client IDs for github.com, gitlab.com, codeberg.org and Azure DevOps (Bitbucket Cloud can't ship one: it needs a secret)
- Formal reviews and assignees on pull requests; issues for Bitbucket and Azure DevOps
- Windows and Linux native clients (see [PORTING.md](PORTING.md))
