# Architecture

GitSync is split into a **UI-free engine** and a **platform UI**. Today both live in `apple/`.

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
