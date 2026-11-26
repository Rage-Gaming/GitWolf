# Changelog

All notable changes are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Hunk and line staging, unstaging and discarding (`PatchBuilder` + `git apply`).
- Multi-repository workspace with a repo rail, persisted across launches.
- ⌘K command palette; frameless window with floating panels and resizable columns.
- `--open=/path` launch flag.
- Initial macOS app (SwiftUI): history with branch graph, working-copy staging and commit,
  branches / remotes / tags / stashes sidebar, fetch / pull / push, live repository watching.
- `GitSyncCore` engine with parsers, graph layout and tests.
