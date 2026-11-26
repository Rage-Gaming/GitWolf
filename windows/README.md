# GitSync for Windows

C# / WinUI 3 (Windows App SDK) port, following [docs/PORTING.md](../docs/PORTING.md). The macOS
app under `apple/` is the executable spec — port its logic and tests, don't invent new semantics.

## Layout

- `src/GitSyncCore/` — the engine (no UI), ported from `apple/Sources/GitSyncCore/`.
- `src/GitSync.Store/` — per-repository state: refresh, selection, operations.
- `src/GitSync.App/` — the WinUI 3 app shell.
- `tests/GitSyncCore.Tests/` — engine tests, ported from `apple/Tests/GitSyncCoreTests/`, run
  against real git in throwaway temp repos (no mocking of git).

## Status

Engine ported so far (see the file map in PORTING.md for the full list and order):

- [x] `GitRunner.swift` -> `GitRunner.cs`
- [x] `Models.swift` -> `Models.cs`
- [x] `Parsers.swift` -> `Parsers.cs`
- [x] `GraphLayout.swift` -> `GraphLayout.cs`
- [x] `PatchBuilder.swift` -> `PatchBuilder.cs`
- [x] `SideBySide.swift` -> `SideBySide.cs`
- [x] `SyntaxHighlighter.swift` -> `SyntaxHighlighter.cs`
- [x] `FileWatcher.swift` -> `FileWatcher.cs` (`System.IO.FileSystemWatcher`, backed by
      `ReadDirectoryChangesW` on Windows)
- [x] `GitRepository.swift` -> `GitRepository.cs`
- [x] `Providers.swift` -> `Providers.cs` (askpass is the same POSIX `sh` script as Swift, run by
      Git for Windows' `sh`; deliberately not a `.cmd`, which would let a crafted remote URL
      inject commands). Unlike Swift, it answers only for the account's own host; the accounts
      layer must set `GitCredential.Scheme` to `http` for plain-HTTP accounts
- [x] `ProviderClient.swift` -> `ProviderClient.cs` (`HttpClient` in place of `URLSession`,
      `System.Text.Json` in place of `JSONSerialization`)

The full engine file map from PORTING.md is now ported, with the tests from
`GitSyncCoreTests.swift`.

Store layer:

- [x] `RepositoryStore.swift` -> `src/GitSync.Store/` (UI-framework independent). Use it from the
      UI thread only, and call `RequestRefresh()` when a window is activated.
- [x] `AppSettings.swift` -> `src/GitSync.App/Services/AppSettings.cs`
- [ ] `Accounts.swift` -> Credential Manager, writing the askpass script with LF endings and no BOM
- [x] `Workspace.swift` (open and recent repositories) -> `src/GitSync.App/Services/Workspace.cs`

73 tests pass against real git and stubbed HTTP.

UI (`src/GitSync.App/`):

- [x] Open a repository (picker, or `GitSync.App.exe <folder>`)
- [x] History with graph, commit files and unified diff
- [x] Changes: stage and unstage files, commit, amend
- [x] Fetch, pull, push using git's own sign-in
- [x] macOS layout: repository rail, top bar, sidebar, history list and commit detail panels
- [x] Syntax colours, author avatars, ref chips, unified and side-by-side diff
- [x] Sidebar: branches, remotes, tags, stashes (click to reveal, double-click to check out,
      right-click for checkout, merge, delete, apply/pop/drop)
- [x] Commit search and context menu; new branch, tag and stash
- [x] Multiple repositories, restored between launches
      (`%LOCALAPPDATA%\GitSync\workspace.json`, paths and view preferences only)
- [x] Jump palette (Ctrl+K), Ctrl+O, Ctrl+Shift+F/L/P
- [ ] Hunk/line staging, discard
- [x] Home dashboard: open, jump, recent repositories, drop a folder to open
- [ ] Clone/new repository, resizable panels
- [x] Settings (Ctrl+,): theme, accent colour, background fetch, history and diff options, git path
      (`%LOCALAPPDATA%\GitSync\settings.json`)
- [ ] Provider accounts

Opening a repository runs git inside it, so its `.git/config` can execute commands (for example
`core.fsmonitor`). Only open folders you trust: they are reopened, and git runs in them, on every launch until
closed from the rail.

## Building

Requires the .NET 10 SDK and, for `GitSync.App`, Visual Studio 2022 with the **Windows App SDK**
workload installed (the WinUI 3 packaging build tasks are not available through the .NET SDK /
`dotnet workload` alone).

```powershell
dotnet build src\GitSyncCore\GitSyncCore.csproj   # engine only, builds anywhere
dotnet test tests\GitSyncCore.Tests\GitSyncCore.Tests.csproj
# The app needs Visual Studio's MSBuild (`dotnet build` lacks the WinUI packaging tasks):
& "C:\Program Files\Microsoft Visual Studio\18\Community\MSBuild\Current\Bin\MSBuild.exe" src\GitSync.App\GitSync.App.csproj -restore -p:Platform=x64 -p:RuntimeIdentifier=win-x64
```

## Notes

- Shell out to the system `git` (`GitRunner`); never reimplement git or use libgit2.
- `GitRunner.ResolveDefaultGitPath` looks on `PATH` first, then the Git for Windows default
  install location, per PORTING.md's platform-specific replacements table.
- Byte-level splitting (`ByteSplitting.SplitBytes`) is used instead of string line-splitting so
  CRLF files and non-UTF8-safe filenames survive, matching the Swift implementation.
- Windows commonly defaults `core.autocrlf` to `true` at the global/system git config level,
  which rewrites line endings on checkout and `git apply`. The engine itself doesn't set this
  (GitRepository should not override a user's repo config), but it's a real source of surprise
  diffs/patches on this platform that macOS doesn't hit by default — worth a settings/onboarding
  note once GitRepository and Settings are ported. The patch-builder tests pin
  `core.autocrlf=false` per test repo so they see exactly the bytes they wrote.
