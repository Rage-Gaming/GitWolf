# Architecture

GitSync is split into a **UI-free engine** and a **platform UI**. Each platform has its own folder and
its own native implementation of both (see [PORTING.md](PORTING.md)). Today only `apple/` exists.

```
apple/Sources/GitSyncCore   engine (Foundation + CoreServices only)
apple/Sources/GitSyncApp    SwiftUI app
```

## Engine (`GitSyncCore`)

| Piece | Responsibility |
|---|---|
| `GitRunner` | Spawns `git`, captures stdout/stderr without deadlocks, sets a safe environment (no prompts, no pager, `GIT_OPTIONAL_LOCKS=0` for reads). |
| `Parsers` | Parse `status --porcelain=v2 -z`, `log -z` with unit-separator fields, `for-each-ref`, `diff --name-status -z`, unified diffs. Byte-level splitting so CRLF files are safe. |
| `GraphLayout` | Turns topologically ordered commits into per-row lane edges for drawing the branch graph. |
| `GitRepository` | Stateless, `Sendable` façade for every read and write operation. |
| `SyntaxHighlighter`, `SideBySide` | Pure helpers for diff presentation: token ranges per line, split-view row pairing. |
| `Sync` | `PullStrategy`, `PushOptions`, `GitError.isPushRejected/isDivergedPull`, `RemoteInfo`, remote add/rename/set-url/remove. |
| `Fork` | `ProviderClient.fork`, `GitRepository.adoptFork` (rename/add remotes, fetch), `ForkRemoteMode`. |
| `Notifications` | `ProviderNotification`, `ProviderClient.notifications()`, `markRead`, `markAllRead`. App side: `NotificationsStore` polls every account. |
| `CIStatus` | `CICheck`, `CIStatus` (overall state, summary), `ProviderClient.ciStatus(repoPath:sha:)`. `CollabItem.headSHA` is the pull request tip. |
| `CollabActions` | Write calls on `ProviderClient` (create PR/issue, comments, merge, close/reopen, labels) with a shared `send` that reports the server's error text. |
| `Providers`, `ProviderClient` | Hosting provider kinds, remote URL parsing, web links, askpass credential environment, REST clients for listing/verifying. See [PROVIDERS.md](PROVIDERS.md). |
| `Operations` | Detects an in-progress merge/rebase/cherry-pick/revert from files in the git dir and runs `--continue`, `--abort`, `--skip`. The snapshot carries it so the UI banner follows the refresh loop. |
| `Reset` | `reset(to:mode:)`, `reflog()` and `resetImpact(to:)` (commits dropped, files modified) so the UI can warn before a hard reset. |
| `Rebase` | `RebasePlan` (actions, validation, todo generation), `rebaseCandidates`, `startInteractiveRebase`, `rebase(onto:)`. Conflicts leave the rebase in progress instead of throwing. |
| `StashTools` | `discardSummary`, `stashFiles`, `stashHash`, `stashHunk` (plumbing-built single-hunk stash). |
| `Signing` | `signature(of:)` (format, state, signer, key), `signingConfig()`, and the `sign` option of `commit`. |
| `Blame` | `blame` (porcelain parser), `fileHistory` (`--follow`), `fileDiff` (rename-aware per-commit diff). |
| `Compare` | `compare(from:to:sinceAncestor:)` returns resolved hashes, changed files, commits and ahead/behind. |
| `CommitMessage` | Pure helpers: `applyPrefix`, `stripPrefix`, `addReference`, `suggestedScopes`; `commitTemplate()` and `recentMessages()` on `GitRepository`. |
| `Ignore` | `IgnoreRules.options(for:)`, `addIgnoreRule(_:local:)`, `stopTracking`. |
| `Hooks` | `HookFailedError`, `HookDiagnosis.diagnose` (is this commit failure a hook?), `activeHooks()`; `commit` throws `HookFailedError`. |
| `HistorySearch` | `HistoryQuery` (scope, text, path, dates) and `GitRepository.search`. |
| Tags (in `GitRepository`) | `createTag(message:)`, `pushTag`, `pushAllTags`, `deleteRemoteTag`; `GitTag` carries `isAnnotated` and `message`. |
| `BranchTools` | `renameBranch`, `setUpstream`, `cleanupCandidates` (merged or upstream gone), `deleteBranches`; `deleteRemoteBranch` lives in `GitRepository`. |
| `FileWatcher` | FSEvents watcher that emits a coalesced "something changed" signal, filtering object-db and lock-file noise. |

## Keeping the UI in sync

`Workspace` owns every open repository; `RepositoryStore` (one per open repo, all kept alive and watching) is the single source of truth for that repo.

1. Triggers: file watcher, app becoming active, any mutating operation, a 5-minute background fetch.
2. `requestRefresh()` coalesces triggers: if a refresh is running, it is re-run once afterwards.
3. A refresh collects one `RepositorySnapshot` (status, log + graph, refs, stashes) off the main thread.
4. State is assigned only when it differs from the current value, so SwiftUI does not re-render
   or flicker.
5. Selection is reconciled: a file that moved between "unstaged" and "staged" stays selected.
6. Diff loads are token-guarded so a slow, stale result never overwrites a newer one.

## Why shell out to git?

Identical behaviour to the user's terminal: hooks, config, credential helpers, SSH setup, LFS,
and every future Git feature. The cost is process spawn overhead, mitigated by batching and
read-only, lock-free commands.

## Hunk and line staging

`DiffParser` keeps the file header, hunks and each line's exact bytes (CRLF intact). `PatchBuilder`
turns a selection of changed lines into a minimal patch: unselected additions/deletions are dropped
or demoted to context depending on direction, and hunk offsets are recomputed. The patch is fed to
`git apply --recount` with `--cached` (stage), `--cached --reverse` (unstage) or `--reverse` (discard).
Diffs are generated with explicit `a/` `b/` prefixes and no external diff tools so user config can't
break patch application. Renames, binary, truncated and non-UTF-8 diffs are read-only.

## App layer (macOS)

| File | Responsibility |
|---|---|
| `Workspace.swift` | Open repositories, selection, persistence, sheets (clone / create / account). |
| `RepositoryStore.swift` | Per-repository state machine described above, plus web links and network operations. |
| `AppSettings.swift` | Typed settings (appearance, accent, fetch interval, diff options, git path) and wiring into new `GitRepository` values (credentials, askpass). |
| `Accounts.swift` | Keychain access, account metadata storage, askpass helper file, `AccountStore`. |
| `Views/*`, `SettingsView.swift`, `AccountsUI.swift` | SwiftUI presentation. |

## Credentials flow

`AppSettings.configure(repo)` gives each `GitRepository` a `credentials` lookup (host to
`GitCredential?`) and the askpass path. Network commands (`fetch`, `pull`, `push`, `clone`) pick the
credential for the origin remote's host and pass it to git through `GIT_ASKPASS` plus environment
variables; local commands never see secrets. Details in [PROVIDERS.md](PROVIDERS.md).

## Docs map

- [FEATURES.md](FEATURES.md): what the app does, section by section.
- [DESIGN.md](DESIGN.md): visual and interaction rules.
- [PROVIDERS.md](PROVIDERS.md): provider accounts, APIs, web links.
- [PORTING.md](PORTING.md): how to build another platform.
- [ROADMAP.md](ROADMAP.md): what is next.
