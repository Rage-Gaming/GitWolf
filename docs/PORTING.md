# Porting GitWolf to another platform

This guide is written for whoever builds the **Windows** (or Linux) client, human or AI. Read it
first, then [FEATURES.md](FEATURES.md) (what to build), [DESIGN.md](DESIGN.md) (how it must look and
feel), [PROVIDERS.md](PROVIDERS.md) and [ARCHITECTURE.md](ARCHITECTURE.md) (how it works).

## Ground rules

1. **Fully native per platform.** Each platform lives in its own top-level folder and uses its own
   language and UI toolkit. Nothing is shared through a cross-platform UI framework.

   | Platform | Folder | Suggested stack |
   |---|---|---|
   | macOS | `apple/` | Swift 6 / SwiftUI (done) |
   | Windows | `windows/` | C# / WinUI 3 (Windows App SDK), or another native stack |
   | Linux | `linux/` | Rust or C / GTK 4 |

2. **Behaviour is shared, code is not.** The macOS code is the executable spec. Port its logic and
   tests; do not invent new semantics.
3. **Shell out to the system `git`.** Never reimplement git, never link libgit2.
4. **Do not touch `apple/`** when working on another platform. Do not add shared code folders.
5. Follow [DESIGN.md](DESIGN.md) (notably: **no gradients**).
6. Conventional commit prefixes (`feat:`, `fix:`, `chore:`, `docs:` ...).

## Suggested order

1. **Engine** (no UI) in your language, with a test suite ported from
   `apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift` (build throw-away temp repos, run real git).
2. **Store layer**: the refresh/selection state machine (see ARCHITECTURE.md).
3. **Main window**: repo rail, sidebar, history with graph, changes + diff.
4. **Staging by hunk/line**, commit, amend.
5. **Sync** (fetch/pull/push, watcher, background fetch).
6. **Clone / init sheets, command palette.**
7. **Settings** (all panes) and theming (light/dark/system, accent).
8. **Provider accounts** (credential store, askpass, browse, web links).
9. Packaging (MSIX / installer), app icon, CI.

## Engine file map (what to port, in order)

All paths under `apple/Sources/GitWolfCore/`.

| File | What it does | Port notes |
|---|---|---|
| `GitRunner.swift` | Spawn git, capture stdout/stderr without deadlock, env, stdin, cancellation, stderr streaming for progress | Use the OS process API; kill the process on cancellation. Env: `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat`, `GIT_EDITOR=true`, `GIT_OPTIONAL_LOCKS=0` for read-only calls, UTF-8 locale, `GIT_SSH_COMMAND="ssh -o BatchMode=yes"` unless the user set one. Read stdout and stderr concurrently. |
| `Models.swift` | `Commit`, `Branch`, `FileChange`, `DiffLine`, `FileDiff`, snapshot types | Plain data types. |
| `Parsers.swift` | status v2 `-z`, log with unit-separator fields, for-each-ref, name-status, unified diff | **Split at byte level**, not on text lines, so CRLF files and odd names survive. |
| `GraphLayout.swift` | Commit rows to lane edges | Children before parents; first parent keeps the lane; extra parents open/join lanes. Test with the ported fixtures. |
| `PatchBuilder.swift` | Build a minimal patch from selected diff lines | Unselected additions are dropped, unselected deletions become context (direction-dependent); recompute hunk headers; apply with `git apply --recount`. |
| `SideBySide.swift` | Pair deletions/additions for split view | Pure function. |
| `SyntaxHighlighter.swift` | Small per-language lexer producing token ranges per diff line | Pure function; port keyword tables and the extension map verbatim. |
| `FileWatcher.swift` | Coalesced change signal | Use `ReadDirectoryChangesW` (Windows) or inotify (Linux). Watch the working tree and `.git`, ignore `.git/objects` and `*.lock`, debounce ~250 ms. |
| `GitRepository.swift` | Every git operation as a method | Exact argument lists are in the file; copy them. Includes clone/init, snapshot, stage/unstage/discard, commit/amend, switch/merge/cherry-pick/revert, tags, stashes, fetch/pull/push. |
| `Providers.swift`, `ProviderClient.swift` | Provider kinds, remote URL parsing, web links, askpass, REST clients | Pure logic plus an HTTP transport. Port with the fixtures in `ProviderTests`. |

App-layer files worth reading for behaviour (not for API shape):
`RepositoryStore.swift` (refresh loop, selection, busy state, web links), `Workspace.swift`
(open repos, persistence), `AppSettings.swift`, `Accounts.swift` (credential storage, askpass
helper), `Views/*` (layout and interactions).

## Platform-specific replacements

| macOS thing | Windows | Linux |
|---|---|---|
| FSEvents (`FileWatcher`) | `ReadDirectoryChangesW` / `FileSystemWatcher` | inotify |
| Keychain (`Accounts.swift`) | Credential Manager (`PasswordVault` / `CredWrite`) | Secret Service (libsecret) |
| `GIT_ASKPASS` shell script | `askpass.cmd` (or a tiny exe) in `%LOCALAPPDATA%\GitWolf` | `askpass.sh`, mode 0700 |
| UserDefaults | `ApplicationData.LocalSettings` / JSON file | GSettings / JSON in `~/.config/gitwolf` |
| `NSApp.appearance` | `RequestedTheme` on the root element | libadwaita `StyleManager` |
| Translucent window material | Mica / Acrylic backdrop (flat fallback) | plain solid surface |
| ⌘ shortcuts | map ⌘ → Ctrl, ⌥ → Alt | same |
| Open on web | `Launcher.LaunchUriAsync` | `xdg-open` |
| `/usr/bin/git` default | resolve `git.exe` from `PATH` / Git for Windows install | `/usr/bin/git` |

Windows specifics: normalise paths (`\` vs `/`) when talking to git and comparing paths; set
`core.quotepath=false`-safe parsing by using `-z` everywhere (already the case); beware long paths
and file locking by antivirus while the watcher refreshes; the askpass helper must be an
executable git can spawn (a `.cmd` works when invoked via the shell git uses on Windows).

## Behavioural invariants (do not regress these)

- Refreshes coalesce; assign UI state only when it differs; never flicker or re-select.
- A file stays selected when it moves between unstaged and staged.
- Stale async results (diffs, snapshots) are dropped using a token.
- Background fetch never steals focus or shows errors loudly.
- Theme/accent changes apply to every open window at once.
- Secrets never appear in command lines, URLs, logs or config files.
- Every open repository keeps syncing, not just the visible one.
- Long lines scroll horizontally in diffs.

## Definition of done for a port

- All engine tests ported and passing against real git.
- Every feature in FEATURES.md present or explicitly listed as missing in the port's README.
- Light and dark verified visually; no gradients; rows fixed-height; no flicker on refresh.
- Works with: a private repo over HTTPS with a token, SSH remote, a self-hosted GitLab.
