# Feature specification

This is the behavioural spec for GitSync. The macOS app (`apple/`) is the reference implementation;
every other platform should match what is described here. Where the spec says "see source", the
Swift file is the ground truth (it is tested; the tests in `apple/Tests/GitSyncCoreTests` are a
ready-made conformance suite to port).

Legend: **[core]** lives in the UI-free engine and must be ported as logic; **[ui]** is presentation
and should follow each platform's native idioms.

## 1. Workspace and repositories

- **Multiple repositories open at once** [ui + core]. A vertical *repo rail* lists them with a live
  badge of uncommitted changes. Every open repo keeps its own watcher and sync loop alive in the
  background, not only the visible one.
- Open set and selection are persisted and restored on launch.
- Open a repository (folder picker; any folder inside a repo resolves to its root via
  `rev-parse --show-toplevel`), `--open=/path` launch flag.
- **Clone** [core `GitRepository.clone`]: URL, destination folder, folder name (auto-derived from the
  URL until edited by the user), live progress parsed from git's stderr (`NN%`), cancellable.
  Offers a copied git URL from the clipboard. Remembers the last destination folder.
  Optionally pick a repository from a connected provider account (section 8).
- **Initialise** [core `GitRepository.initialize`]: name, location, initial branch (default `main`).
- **⌘K command palette** [ui]: fuzzy list of repositories, branches (checkout), actions (fetch,
  pull, push, new branch, show history/changes, open/clone/new repository, web links).

## 2. History

- Commit list with a **branch graph** [core `GraphLayout`], ref chips (branch, remote, tag, HEAD),
  author avatar (stable colour from email hash), relative date, short hash.
- Fixed-height rows (50 pt) so scrolling and the graph never jitter.
- Loads `Commits per page` commits; search box filters the loaded commits.
- Commit detail: full message, parents, changed files with status badges, diff per file.
- Context menu: checkout (detached), new branch here, new tag here, cherry-pick, revert,
  copy hash, **Open on <provider>**.

## 3. Working copy (changes)

- Unstaged / staged / untracked lists, status badges `A M D R C T U ?` with colours
  (added green, modified orange, deleted red, renamed blue, untracked teal, conflicted pink).
- Stage / unstage / discard per file, stage all / unstage all.
- **Hunk and line staging** [core `PatchBuilder`]: click a gutter to select a line, shift-click for a
  range, stage/unstage/discard the selection. Implemented by building a minimal patch and running
  `git apply --recount` (`--cached`, `--cached --reverse`, `--reverse`). Renames, binary, truncated
  and non-UTF-8 diffs are read-only.
- Commit box: multi-line message, Commit button, **amend** (pre-fills the HEAD message).
- Selection follows a file between the unstaged and staged areas.
- **In-progress operation banner** [core `OperationDetector`]: while a merge, rebase, cherry-pick or
  revert is unfinished, a flat orange banner under the top bar shows the operation (with "step N of M"
  for rebases and sequences), the number of conflicted files, **Show Conflicts**, **Skip** (not for
  merges), **Abort** (confirmed) and **Continue** (disabled until conflicts are resolved). Detection
  reads the git dir (`rebase-merge/`, `rebase-apply/`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`,
  `REVERT_HEAD`, `sequencer/`), following a `gitdir:` pointer for worktrees/submodules; actions run
  `git <op> --continue|--abort|--skip`. Also in the command palette.
- **Conflict resolution** [core `ConflictDocument`]: selecting a file in the Conflicts group opens a
  resolver in the detail pane. The file is parsed for `<<<<<<<` / `|||||||` (diff3 base) / `=======` /
  `>>>>>>>` blocks (exactly 7 characters; unterminated blocks stay plain text). Each block gets
  Ours, Theirs, Both and Both-Theirs-First, shown side by side with the branch labels. **Mark as
  Resolved** is enabled once every block has a choice; it writes the file (CRLF and missing final
  newline preserved) and runs `git add`. Files with no markers (deleted by us/them, added by both,
  binary) offer Keep Ours / Keep Theirs / Delete via `git checkout --ours|--theirs` and `git rm`,
  chosen from `git ls-files -u` stages. The row context menu has Resolve Using Ours / Theirs.

## 3b. Reset, reflog and undo

- **Reset Branch to Here** in the commit context menu: Soft (keep changes staged), Mixed (keep
  changes unstaged), Hard (discard changes). `git reset --soft|--mixed|--hard <commit>`.
- **Hard reset always asks first**, saying how many commits leave the branch and how many files
  with uncommitted changes will be lost (`git rev-list --count target..HEAD` + status).
- **Reflog…** (Repository menu, palette): `git reflog show HEAD`, newest first, with relative
  dates; per entry Reset (soft/mixed/hard), Checkout (detached) and New Branch Here.
- **Undo Last Change…** (⌥⌘Z): confirms with the last reflog message, then
  `git reset --keep HEAD@{1}`, which keeps uncommitted work and refuses rather than overwrite it.

## 3c. Rebase

- **Interactive Rebase from Here…** (commit menu): lists that commit and everything after it on the
  branch, oldest first. Drag to reorder; per commit Pick, Reword (inline message editor), Squash,
  Fixup, Drop. Refused with an explanation for ranges containing merge commits (git would flatten
  them) and while another operation is in progress. The plan is validated before it runs: the first
  kept commit can't be squash/fixup, at least one commit is kept, rewords have a message.
- Implementation [core `RebasePlan`]: writes the todo file and runs `git rebase -i --autostash
  <parent>` (or `--root`) with `GIT_SEQUENCE_EDITOR="cp <todo>"`, so no editor opens. A reword is
  `pick` plus `exec git commit --amend -F <file>` after any squash/fixup folded into it; messages
  live in `<gitdir>/gitsync-rebase/`, removed when the rebase ends, and are never put on a command line.
- **Rebase Current Branch onto This** (branch context menu): `git rebase --autostash <branch>`.
- **Pull strategy** setting: Merge (default) or Rebase (`git pull --rebase --autostash`).
- A conflict is not an error: the rebase stays in progress and the operation banner takes over.

## 4. Diff view

- **Unified and side-by-side** layouts (setting; toggle in the diff header). Side-by-side pairing is
  [core `SideBySide.rows`]: consecutive deletions/additions are paired row by row.
- Line numbers for both sides, hunk headers, "no newline" notes, CRLF preserved, long lines scroll
  horizontally (do not wrap).
- **Syntax highlighting** [core `SyntaxHighlighter`]: a deliberately small lexer, not a grammar
  engine. Token kinds: keyword, string, comment, number, type, attribute, directive, tag, plain.
  Tracks multi-line block comments separately for the old and new side. Languages are chosen by
  file extension / name (Swift, JS/TS, C-family, Rust, Go, Python, Ruby, PHP, Java/Kotlin/C#/Scala,
  shell, SQL, Lua, JSON, YAML/TOML/INI, HTML/XML, CSS/SCSS, Dockerfile, Makefile; see
  `Language.extensionMap`). Colours are a fixed palette per
  light/dark appearance; no gradients.
- Diff context lines configurable (`-U<n>`); truncated at 6000 lines with a notice.
- Diffs always use `--no-ext-diff --no-textconv --no-color` with explicit `a/` `b/` prefixes so user
  config cannot break patch application.

## 5. Branches, tags, stashes, remotes (sidebar)

- Local and remote branches with ahead/behind, checkout (remote branches create a tracking branch),
  merge into current, delete (force on confirm), create from any commit.
- Tags: create at commit, delete.
- Stashes: push (including untracked, optional message), apply, pop, drop.
- Remotes list. Header chip "Provider · owner/repo ↗" opens the repo on the web.

## 6. Sync

- Fetch (`fetch --all --prune`), pull (fast-forward/merge, no editor), push (sets upstream on first
  push). Ahead/behind badges in the toolbar.
- **Always live** [core `FileWatcher`]: watch the working tree and `.git`, ignore `.git/objects` and
  `*.lock`, coalesce events (≈250 ms), refresh one snapshot. Also refresh on app activation and after
  any mutation. Background fetch on a timer (setting; default 5 min, 0 = off).
- Busy indicator for long operations; cancellation via task cancellation killing the process.

## 7. Settings

| Key | Values |
|---|---|
| appearance | system / light / dark (applied app-wide, not per view) |
| accent | indigo, blue, purple, pink, red, orange, green, teal |
| autoFetchMinutes | 0 (never) / 1 / 5 (default) / 15 / 30 |
| commitPageSize | 500 / 1000 (default) / 2000 / 5000 |
| diffContext | 1 / 3 / 4 (default) / 6 / 10 lines |
| syntaxHighlighting | on / off |
| diffLayout | unified / split |
| gitPath | optional custom git executable (empty = system git) |

Panes: **General**, **Accounts**, **Git**, **Shortcuts** (read-only cheat-sheet).
A live change in appearance or accent must re-render the whole UI at once (no partial colour
switches; this was a real bug on macOS).

## 8. Hosting provider accounts

Full details in [PROVIDERS.md](PROVIDERS.md). Summary:

- Providers: GitHub, GitLab, Bitbucket (Cloud and Data Center), Gitea/Forgejo/Codeberg, Azure
  DevOps. Cloud and self-hosted/enterprise (custom host, port, http).
- Sign in with the **browser (OAuth)**, an **access token**, or a **username and password**; multiple accounts, even per host. OAuth: GitHub device flow, GitLab/Gitea PKCE.
- Secrets live in the OS credential store (macOS Keychain; Windows Credential Manager; Linux Secret
  Service). Never in preferences, URLs, command lines or git config.
- Authenticated fetch/pull/push/clone through `GIT_ASKPASS`.
- Browse and clone repositories from an account; "Open on web" links (repo, branch, new PR/MR, commit).

## 8b. Pull requests and issues

- Tabs **Pulls** (**Merges** on GitLab) and **Issues** appear next to History/Changes when the
  origin remote is on a supported provider (GitHub, GitLab, Gitea/Forgejo; Bitbucket Cloud pull
  requests only). Also in the ⌘K palette and the Repository menu.
- List: Open / Closed / All filter, search (title, author, number, label; filters loaded items),
  30 per page with "Load more", reload button, state icon (open green, draft grey, merged purple,
  closed red), `#number · author · age`, comment count, label chips.
- Detail: title, state badge, branches (`source → target`), labels, description (inline markdown),
  Open on web, Copy link, and **Check Out Branch** when the PR's source branch exists as a remote
  branch.
- Public repositories work without an account (rate-limited); private ones use the connected account.
  Errors say whether to add an account. Stale responses are dropped; data older than 60 s reloads
  when the tab opens.
- API details in [PROVIDERS.md](PROVIDERS.md#pull-requests-and-issues).

## 9. Keyboard shortcuts (macOS; map ⌘ to Ctrl on Windows/Linux)

| Action | Keys |
|---|---|
| Open / Clone / New repository | ⌘O / ⇧⌘O / ⇧⌘N |
| Close repository | ⇧⌘W |
| Jump palette | ⌘K |
| Repository 1-9 / next / previous | ⌘1…9 / ⌃⇥ / ⌃⇧⇥ |
| History / Changes | ⌥⌘1 / ⌥⌘2 |
| Refresh / Fetch / Pull / Push | ⌘R / ⇧⌘F / ⇧⌘L / ⇧⌘P |
| Open on provider | ⇧⌘G |
| Settings | ⌘, |

## 10. Not built yet

See [ROADMAP.md](ROADMAP.md): interactive rebase, reset, conflict-resolution UI, signing status,
submodules/worktrees, LFS, OAuth sign-in, pull-request/issue/CI lists, notarised releases.
