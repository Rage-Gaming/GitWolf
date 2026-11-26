# Porting GitSync

Each platform has its own top-level folder with a fully native implementation:

| Platform | Folder | Language / UI |
|---|---|---|
| macOS | `apple/` | Swift / SwiftUI |
| Windows | `windows/` (planned) | e.g. C# / WinUI 3 |
| Linux | `linux/` (planned) | e.g. Rust or C / GTK 4 |

Nothing is shared at the code level. What is shared is **behaviour**, specified here and
demonstrated by `apple/Sources/GitSyncCore`:

1. Run the system `git`, never a reimplementation.
2. Read with `status --porcelain=v2 -z --branch --untracked-files=all`, `log --all --topo-order -z`,
   `for-each-ref`, `stash list`, `diff` variants. See `GitRepository.swift` for exact arguments.
3. Pass `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, `GIT_PAGER=cat` and a UTF-8 locale.
4. Compute the commit graph with the lane algorithm in `GraphLayout.swift` (children before
   parents; first parent keeps the lane; extra parents open or join lanes).
5. Watch the working tree and `.git`, ignore `.git/objects` and `*.lock`, coalesce events
   (~250 ms), then refresh one snapshot.
6. Mirror the store semantics in `docs/ARCHITECTURE.md`: coalesced refresh, assign only on change,
   follow selection across areas, discard stale async results.

Port the engine first (with tests ported from `GitSyncCoreTests`), then the UI.
