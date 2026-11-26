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
- **Dock / taskbar integration** [ui; core `BadgeLabel`]. The app icon badge shows the total files with
  uncommitted changes across open repositories (`BadgeLabel.text`: none for 0, `99+` above 99). The
  Dock (taskbar jump list on Windows/Linux) menu lists up to 8 recent repositories, and File > Open
  Recent lists the recents with *Clear Menu*.
- **Home screen pins and groups** [ui; core `HomeLayout`]. With no repository selected the home screen
  shows *Pinned*, one section per user-named *Group*, then *Recent*. Context menu on a card: Pin/Unpin,
  Add to Group (toggle, New Group…), Reveal, Remove from Home. `HomeLayout` is a Codable value type
  (pinned paths, groups of paths) persisted as JSON; missing folders are pruned on load.
- **Menu bar / tray icon** [ui]. Status item (a native status item built when the menu opens; a declarative, observing tray scene caused a redraw loop on macOS) with the branch symbol and the total changed-file count
  (`BadgeLabel`); menu: open repositories (name, branch, changes; selecting one focuses it), Open Recent,
  Open Repository…, Show GitSync, Quit. Setting `showMenuBarExtra` (default on). Windows/Linux: the
  notification-area / tray icon with the same menu.
- Menu bar hygiene: only menus that apply are shown (no New Window, toolbar/sidebar toggles or Format).
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

## 3d. Discard and stash safety

- **Discard confirmations say what is lost** [core `DiscardSummary`]: for files, "Changes in N files
  (+A lines added, −R removed) will be lost", binary files counted, untracked files listed with
  their total size as "will be deleted". Hunk and line discards show "+A −R" for that selection.
- **Stash this hunk**: a tray button on each unstaged hunk header. Builds the stash with plumbing
  (temporary `GIT_INDEX_FILE`: `read-tree HEAD`, `apply --cached`, `write-tree`, `commit-tree` for
  the index and stash commits, `git stash store`), then removes the hunk from the working tree with
  `git apply --reverse`. If the reverse apply fails the stash entry is dropped again. Disabled for
  files with staged changes (the stash is built on HEAD); a message can be given.
- **Stash preview**: click a stash in the sidebar (or "Preview Changes") to see its files and
  diffs in the main panes, with Apply / Pop / Drop; Drop asks first. Diffs use the stash commit
  against its first parent. The view closes if the stash list changes under it.
- Apply/Pop fall back to applying the stash as a patch when git refuses because a touched file has
  other local changes (only for stashes without untracked files).

## 3e. Commit signing

- **Signature badge** in the commit detail pane [core `signature(of:)`]: green "Verified SSH/GPG
  signature" with signer and key, orange when valid but untrusted, expired, or git can't check it
  (no public key; for SSH, no `gpg.ssh.allowedSignersFile`), red for a bad or revoked signature.
  The format comes from the commit's `gpgsig` header and the state from `git log --format=%G?`;
  unsigned commits are never sent to gpg/ssh-keygen, so history stays fast, and the check runs
  only for the selected commit.
- **Sign checkbox** in the commit box, shown when signing is configured (`commit.gpgsign` or
  `user.signingkey`; format from `gpg.format`). It starts from `commit.gpgsign`; an explicit choice
  that differs from config is passed as `--gpg-sign` / `--no-gpg-sign`. GPG needs a pinentry that
  works without a terminal (e.g. pinentry-mac); SSH keys need the agent or an unencrypted key.

## 3f. Blame and file history

- **History & Blame…** in the context menu of a changed file or a file inside a commit opens a sheet
  with two tabs.
- **History** [core `fileHistory`, `fileDiff`]: `git log --follow` for the file, newest first; select a
  commit to see what it changed in that file. For commits before a rename the diff looks up the
  file's older name (`--name-status` under `--follow`) so the diff isn't empty. Context menu: Show in History.
- **Blame** [core `blame`]: `git blame --porcelain`. Author, date and a colour bar per commit run on
  the first line of each run; uncommitted lines show "Not committed". Clicking the author jumps to
  the commit in History. Untracked and binary files report git's error instead.

## 3g. Compare refs

- **Compare Refs…** (Repository menu ⌥⌘C, palette), **Compare with Current Branch** (branch and
  commit context menus). A Compare panel replaces the main column: two ref fields (type anything,
  or pick from branches, remotes and tags), swap, and **Only changes since the common ancestor**
  (`git diff from...to`; off compares the two tips directly).
- Shows "N ahead / M behind", the commits only in the compared ref (click one to open it in
  History), and the changed files; selecting a file shows its diff in the detail pane.
- Refs are resolved with `rev-parse --verify <ref>^{commit}` first; unknown refs and option-like
  names (`-x`) give a plain message. Diffs use `DiffTarget.Source.compare(base:head:)` with the
  resolved hashes.

## 3h. Branch tools

- **Rename** (local branch context menu): `git branch -m old new`, name validated with `git check-ref-format --branch`.
- **Track Remote Branch / Stop Tracking**: `git branch --set-upstream-to=<remote/branch>` / `--unset-upstream`.
- **Delete on Remote** (remote branch context menu): confirmation, then `git push <remote> --delete <branch>`.
- **Clean Up Branches…** (Repository menu, palette): local branches in `git branch --merged <current>`, plus branches whose upstream is `gone` (`%(upstream:track)`). Never lists the current branch or main, master, develop, dev, trunk, release. Merged branches are pre-selected; an unmerged "gone" branch is tagged and warns that commits are lost. Merged branches use `branch -d`, unmerged `branch -D`.

## 3i. Tags

- **New Tag…** (commit context menu): name, optional message (non-empty → `git tag -a -m`, annotated; empty → lightweight), optional "Push to <remote>".
- Tag rows: tooltip shows annotated message; context menu has **Push to <remote>**, **Delete on <remote>…** (confirmation, `git push <remote> --delete refs/tags/<tag>`) and **Delete Local Tag**. A "Push All Tags" link appears when there are several (`git push <remote> --tags`).
- Tag list reads `for-each-ref` with the peeled object (`%(*objectname)`) so annotated tags point at their commit, plus `%(objecttype)` and `%(contents:subject)`.

## 3j. History search

The History search field filters loaded commits (message, author, hash prefix). The options button next to it widens the search; whenever a scope other than the default, a file/folder, or a date is set, git does the search over all refs (debounced 300 ms, max 500 results, graph hidden while searching):

| Scope | Git flags |
|---|---|
| Message (all history) | `--grep=<text> --fixed-strings --regexp-ignore-case` |
| Author | `--author=<text> --regexp-ignore-case` |
| Code added or removed | `-S<text>` (pickaxe) |
| Code matching regex | `-G<regex>` |
| File or folder | `-- <path>` |
| From / To dates | `--since=<date> 00:00:00` / `--until=<date> 23:59:59` |

User text is always glued to its flag (`--grep=…`, `-S…`) so it can never be read as an option.

## 3k. Hook output

If `git commit` fails and an executable `pre-commit`, `prepare-commit-msg` or `commit-msg` hook exists (looked up with `git rev-parse --git-path hooks`, so `core.hooksPath` is honoured), the failure is treated as a hook failure unless git's own message explains it (nothing to commit, identity unknown, GPG failure, empty message, merge in progress…). The sheet shows the hook name and its full output with ANSI colour codes removed, **Copy Output**, and **Commit Without Hooks** (`git commit --no-verify`). The commit message draft is kept. Hook stdout is redirected to stderr by git, so stderr holds all output.

## 3l. Ignore helper

Context menu on a change row, **Ignore**: options are generated from the path (`/path/to/file`, `name`, `*.ext`, `/folder/`; special characters `* ? [ ] \` and a leading `#` or `!` are escaped). Rules are appended to `.gitignore`, or to `git rev-parse --git-path info/exclude` under **Only on This Machine**; duplicates are skipped. For a file that is already tracked the app also runs `git rm --cached -r` on the file (or, for a folder rule, the folder) so the rule takes effect; the file stays on disk.

## 3m. Commit message helpers

A menu button next to "Amend last commit":
- **Type Prefix**: feat, fix, docs, style, refactor, perf, test, build, ci, chore, revert. Sets or replaces a `type(scope): ` prefix on the first line (regex `^[a-z]+(\([^)]*\))?!?:\s*`). Scope entries offer up to three top-level folders of the staged files.
- **Reference Issue**: lists up to 15 open issues from the provider; appends `Closes #N` or `Refs #N` in a footer after a blank line, joining an existing reference block and never duplicating.
- **Use Repository Template**: the file named by `commit.template` (`~/` and repo-relative paths supported, lines starting with `#` removed).
- **Reuse Recent Message**: your last 10 distinct commit messages.
- **Check Spelling While Typing**: the system spell checker on the message field (preference "spellCheckCommitMessages", default on).

## 4. Diff view

- **Unified and side-by-side** layouts (setting; toggle in the diff header). Side-by-side pairing is
  [core `SideBySide.rows`]: consecutive deletions/additions are paired row by row.
- **Word-level highlighting** [core `InlineDiff`, `FileDiff.inlineRanges`]: each run of deleted lines is
  paired in order with the added run that follows; both lines are tokenised (words, whitespace, single
  punctuation), an LCS marks the differing tokens, and those character ranges get a stronger
  background. Skipped when more than 70% of a line changed or a line has over 600 tokens.
- **Ignore whitespace** [core `GitRepository.ignoreWhitespace`]: adds `-w`. `FileDiff.ignoresWhitespace`
  makes `canPatch` false, so hunk/line staging is disabled while it is on.
- **Show whole file** [core `GitRepository.fullFileDiffs`]: `-U1000000`. Combined with **folding**
  [core `FileDiff.collapsibleRuns(minimum: 8, keep: 3)`]: unchanged runs of 8+ lines collapse to a row
  "N unchanged lines" (3 lines stay beside every change); click to expand. Both toggles are in the diff
  header and stored in settings.
- **Image diffs** [core `GitRepository.imageVersions`, `isImagePath`]: for binary image files the
  old/new bytes are read (`git show :path`, `HEAD:path`, `<commit>^:path`, or the working file) and shown
  side by side with pixel size and file size; a missing side reads "Did not exist" / "Deleted". SVG stays
  a text diff.
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
- **Pull strategy** (context menu on Pull, Repository menu, palette): merge, rebase (`--autostash`), or
  fast-forward only (`--ff-only`; a diverged branch fails with a clear message). The default comes from
  the Settings toggle.
- **Push options** (context menu on Push): plain; with tags (`--tags`); force with lease
  (`--force-with-lease`, never plain `--force`, always behind a confirmation); push to a chosen remote
  (sets upstream when the branch has none).
- **Rejected push**: detect `[rejected]`, `non-fast-forward`, `fetch first`, `stale info` in stderr and
  offer Pull / Force Push… / Cancel. If a lease push is rejected, tell the user to fetch first.
- **Remotes sheet**: list (`git remote -v`, redact any `user:password@`), add, rename, set URL, remove
  (confirm), fetch one remote, push to one remote. Names: non-empty, no whitespace, no leading `-`.
  Reject URLs with an embedded password or a leading `-`.
- **Always live** [core `FileWatcher`]: watch the working tree and `.git`, ignore `.git/objects` and
  `*.lock`, coalesce events (≈250 ms), refresh one snapshot. Also refresh on app activation and after
  any mutation. Background fetch on a timer (setting; default 5 min, 0 = off).
- Busy indicator for long operations; cancellation via task cancellation killing the process.

## 6a. File type icons

[core `FileIcons.swift`] `FileIcons.icon(forPath:)` maps a path to `{name, glyph, color, darkText}`. Look up by
exact lowercase file name first (`package.json`, `dockerfile`, `.gitignore`, `makefile`), then prefixes
(`.env*`, `readme*`, `license*`, `dockerfile*`), then `.d.ts`/`.min.js`, then the last extension, else a grey
generic file. Glyphs are `letters` (short text on a rounded square in the brand colour, dark text on light
colours like JS yellow), `symbol` (SF Symbol name; use the nearest icon on other platforms) or `react` (three
ellipses at 0°, 60° and 120° plus a centre dot, stroked in #61DAFB). Flat colours only, no gradients. Folders use the glyph
`folder(innerSymbol?)`: `FileIcons.folderIcon(named:)` looks the name up (case-insensitive: `src`, `docs`,
`tests`, `assets`, `components`, `scripts`, `config`, `.github`, `node_modules`, `dist`…), and
`folderIcon(containing: path)` uses the nearest folder, falling back to a container folder (`node_modules`,
`vendor`, `.github`, `dist`, `build`…) higher up. Draw a folder in the brand colour with the inner symbol small and
white on it, before the directory text of a file row. Draw it at
the start of every file row (after the status badge), in the diff header and file history.

Branches [`FileIcons.branchIcon(named:)`]: exact names first (`main`/`master`/`trunk` star, `develop`/`dev`
hammer, `staging` flag, `production` shield), then the first word split on `/`, `-` or `_` (`feature`, `feat`,
`fix`, `bugfix`, `hotfix`, `release`, `chore`, `docs`, `test`, `refactor`, `perf`, `style`, `wip`, `revert`,
`dependabot`, `pr`, `issue`), a leading number means an issue branch, anything else is the plain branch symbol.
In the sidebar draw the symbol in its colour; mark the current branch with a small green check badge on the icon
(and a semibold name) rather than replacing the icon.

Tags [`FileIcons.tagIcon(named:isAnnotated:)`], first match wins: `nightly`/`daily` moon; `-rc`/`.rc` checkered flag;
`alpha`/`beta`/`preview`/`snapshot`/`canary`/`-dev` test tube; `latest`/`stable`/`current` seal; `lts` shield;
`deploy`/`prod`/`staging`/`live` paper plane; `backup`/`archive`/`old`/`legacy` archive box; `N.0` or `N.0.0`
(N ≥ 1) star; any other dotted version a tag (filled if annotated, outlined if lightweight); else a plain tag.

## 6b. Scale and power

- **Bisect** [core `Bisect.swift`]: state comes from `BISECT_LOG` (marks, and the
  `# first bad commit:` line). Start with a bad and good commit (`bisect start <bad> <good> --`), mark HEAD or
  a given hash with `bisect good|bad|skip`, parse `Bisecting: N revisions left…` for progress, `bisect reset`
  to end. UI: context-menu picks, a banner with Skip/Bad/Good/Stop, then "Show Commit"/"Finish".
- **Patches** [`Patches.swift`]: `format-patch -1 <hash> -o dir`; `diff --binary HEAD`; `apply --check` before
  `apply [--index]`; `am --3way`. An `am` in progress is detected by `rebase-apply/applying` and shown as the
  operation "Applying patches" (continue/skip/abort use `git am`).
- **Worktrees** [`Worktrees.swift`]: `worktree list --porcelain` (first entry is the main one; `locked`,
  `prunable`), `add [-b]`, `remove` (never forced), `prune`. Open one as another repository.
- **Submodules** [`Submodules.swift`]: `submodule status` (flags ` `, `-`, `+`, `U`) joined with URLs from
  `.gitmodules`; `update --init --recursive [-- path]`, `update --remote`, `add -- url path` (refuse `-`
  prefixes). Network calls use the account credential like fetch.
- **LFS** [`LFS.swift`]: `check-attr -z --stdin filter` marks paths whose filter is `lfs`; shown as a badge. Only
  run when `.gitattributes` mentions `filter=lfs`. `LFSPointer.parse` reads pointer files.
- **Clone options** [`CloneOptions.swift`]: `--depth`, `--filter=blob:none|tree:0`, `--single-branch`,
  `--branch` (not accepted with a leading `-`), `--recurse-submodules`. `rev-parse --is-shallow-repository`
  drives a banner; `fetch --unshallow` fetches the rest.
- **Large repositories** [`Performance.swift`]: history is paged. `git log --topo-order` walks all of
  history without a commit-graph, so if a refresh takes over 0.5s write it once with
  `commit-graph write --reachable --changed-paths` in the background.

## 6c. Open in… and custom actions

- **Open in Finder / Terminal / editor** [ui]. Reveal the repo root in the file manager, open a
  terminal at it, or open it in a user-chosen editor (setting `editorApp`, default Visual Studio
  Code). macOS uses `open -a <app> <path>` with the path as an argument. Shortcuts ⌥⌘T / ⌥⌘E / ⇧⌥⌘R.
- **Custom actions** [core `CustomAction`, `CustomActionRunner`]. Named shell commands stored in
  settings. Run through the system shell (`/bin/sh -c`; `cmd`/`sh` on other platforms) with the repo
  root as working directory and `GITSYNC_REPO` / `GITSYNC_BRANCH` in the environment. Values are never
  interpolated into the command text. Non-zero exit shows the code and the last 600 characters of
  output. Listed in the toolbar menu, Repository menu and ⌘K palette.

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

### Fork

Repository menu and palette: **Fork Repository…** (needs a connected account on GitHub, GitLab, Gitea or Bitbucket Cloud). Calls the provider's fork API (returns the existing fork if you already have one), then wires the checkout: **Use the fork as origin** (`git remote rename origin upstream`, `git remote add origin <fork>`; refused if `upstream` already exists) or **Add as another remote** (default name `fork`). The fork URL is SSH when the current origin uses SSH, HTTPS otherwise. It then fetches the new remote; GitHub copies in the background so the fetch is retried once after 4 s. Endpoints in [PROVIDERS.md](PROVIDERS.md#fork).

### Notifications

Bell button in the repository toolbar (only when a GitHub, GitLab or Gitea account exists), Repository menu and palette. Loads from every connected account at start and every 5 minutes; the badge counts unread items. The sheet lists title, `owner/repo`, age and a reason chip (Review requested, Mentioned, Assigned, Activity). Clicking a row opens it on the web and marks it read; **Mark All as Read** clears everything. A GitHub token without the `notifications` scope shows a warning instead of an empty list. Bitbucket and Azure DevOps have no notifications API. Endpoints in [PROVIDERS.md](PROVIDERS.md#notifications).

### CI checks

Selecting a pushed commit (History) or a pull request shows a pill with the overall result (worst state wins: failure, then pending, then success) that expands to each check with a **Details** link. Looked up by commit SHA (a pull request uses its head commit), cached for 60 s, hidden when the server has no checks or doesn't know the commit. Works without an account on public repositories. Endpoints in [PROVIDERS.md](PROVIDERS.md#ci-checks).

### Actions (need a connected account)

- **New Pull Request…** / **New Issue…**: "+" in the list header, Repository menu, palette. The PR form
  shows `current branch → base` (base defaults to main/master/develop/trunk), title (the branch's only
  commit subject, otherwise the humanised branch name), Markdown description, "Open as draft". If the
  branch has no upstream or unpushed commits it is pushed first. A rejected request shows the
  server's reason (for example "a pull request already exists"). The new item is selected.
- Detail pane: **Merge** menu (merge commit / squash / rebase) with a confirmation, disabled for drafts;
  **Close** / **Reopen**; **Labels** menu with checkmarks (GitHub, GitLab); a **Conversation** with the
  comments (Markdown, GitLab system notes hidden) and a comment box (⌘↩).
- Not supported: reopening a declined Bitbucket PR, labels on Gitea (they need ids), rebase on GitLab,
  anything for Azure DevOps, assignees and formal reviews.

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

## 9a. Updates and releases

- **Update check** [core `UpdateChecker`, `AppVersion`; ui `UpdateManager`]. `GET /repos/<repo>/releases/latest`
  with no credentials. Ignored: drafts, pre-releases, 404 (no releases), and any `html_url` that is not
  `https://github.com/...`. Offered through an alert with Download (opens the page), Later, Skip This
  Version. Automatic check at most once a day, only for packaged builds that have a version; setting
  `checkForUpdates` (default on). Also a menu command. Never downloads or installs.
- Releases are produced by `Scripts/release.sh` / `docs/RELEASING.md`.

## 9b. Accessibility and localisation

- Every interactive element has a spoken label; icon-only buttons use their tooltip text. Rows that
  select on click are announced as selectable buttons with state. File rows expose *Stage*/*Unstage*
  as accessibility actions because the visible button only appears on hover. Change kinds have plain
  names [core `ChangeKind.spokenName`]. Ports should map this to UI Automation (Windows) and AT-SPI
  (Linux) names, and make every action reachable without a pointer.
- Keyboard: arrows move through commits and changed files, the command palette is fully keyboard
  driven, and every menu action has an item in the menu bar.
- **Strings**: user-visible text is kept as literals so the toolkit's own lookup can translate it.
  macOS: `Scripts/extract-strings.py` writes `Resources/en.lproj/Localizable.strings` (key = English text);
  strings with interpolation are listed in `Interpolated.txt` and need `%@`/`%lld` keys added by hand.
  Other platforms should extract the same set of strings into their resource format (`.resw`, `.po`).
  Translation files are not shipped yet.

## 10. Not built yet

See [ROADMAP.md](ROADMAP.md): LFS actions, notarised releases.
