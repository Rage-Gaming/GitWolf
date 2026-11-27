# GitWolf: instructions for AI assistants

GitWolf is an open-source, native Git client. macOS (`apple/`, Swift/SwiftUI) is the reference
implementation. Other platforms (`windows/`, `linux/`) are separate native implementations that must
match its behaviour.

Read before working:
- `docs/PORTING.md`: how to build another platform, file map, invariants, definition of done.
- `docs/FEATURES.md`: the feature spec.
- `docs/DESIGN.md`: visual rules. **No gradients, ever.** Native controls, flat colour, no jank.
- `docs/PROVIDERS.md`: provider accounts, GIT_ASKPASS flow, API endpoints, web links.
- `docs/ARCHITECTURE.md`: engine, refresh loop, patch staging.

Rules:
- Shell out to the system `git`; never reimplement git or use libgit2.
- Do not modify `apple/` when working on another platform; no shared UI code between platforms.
- Never put secrets in URLs, command lines, logs or config files.
- Port the engine tests (`apple/Tests/GitWolfCoreTests`) and keep them passing against real git.
- Conventional commit prefixes (`feat:`, `fix:`, `chore:`, `docs:`). Commit only when asked; do not push.

macOS build/test: `cd apple && swift build && swift test` (needs Xcode 16+; set
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points elsewhere).
