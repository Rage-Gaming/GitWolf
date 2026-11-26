# GitSync

A fast, clean, native Git client. Think Sourcetree, without the rough edges.

> **Status:** early development (v0.1). macOS is the first supported platform. Windows and Linux
> clients, written natively for each platform, are planned.

## Goals

- **Always in sync.** The UI watches the repository (working tree, index, refs) and reflects
  changes made anywhere: terminal, editor, another Git tool. No manual refresh.
- **No UI jank.** Native controls, stable selection, no flicker on refresh, fixed-height rows.
- **Native on every platform.** Each platform gets its own UI in its own language. Nothing is
  shared through a cross-platform UI toolkit.
- **Uses your Git.** All operations shell out to the system `git`, so behaviour, hooks, config and
  credentials match what you already use.

## Features (v0.1, macOS)

- **Multiple repositories at once**: a repo rail with live change badges; every open repo keeps syncing in the background, and open repos are restored on relaunch
- **⌘K jump palette** for switching repositories and branches and running actions
- Commit history with branch graph, search, and per-commit file diffs
- Working copy: stage / unstage / discard per file, commit and amend
- Branches, remotes, tags and stashes in the sidebar, with checkout / merge / delete
- Fetch, pull, push with ahead/behind badges; automatic background fetch
- Cherry-pick, revert, create tag or branch from any commit
- Live file-system watching with coalesced refreshes

See [docs/ROADMAP.md](docs/ROADMAP.md) for what is next (hunk/line staging, syntax highlighting,
clone, rebase, and more).

## Building (macOS)

Requirements: macOS 15+, Xcode 16+ (the SwiftUI macros ship with Xcode), Git.

```bash
cd apple
swift build          # debug build
swift test           # run the test suite
swift run GitSync    # launch (add --open=/path/to/repo to open a repo directly)
./Scripts/bundle.sh  # produce build/GitSync.app
```

If `swift build` reports a missing `SwiftUIMacros` plugin, point the toolchain at full Xcode:
`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

## Repository layout

```
apple/   Everything Apple-specific: Swift package, SwiftUI app, tests, packaging
docs/    Architecture, porting guide, roadmap
.github/ CI, issue and PR templates
```

Platform code lives in its own top-level folder (`apple/` today; `windows/`, `linux/` later) so
ports never touch one another. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and
[docs/PORTING.md](docs/PORTING.md).

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) and our
[Code of Conduct](CODE_OF_CONDUCT.md). Report security issues as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
