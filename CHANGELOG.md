# Changelog

All notable changes are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Diff improvements: changed words are highlighted inside modified lines (paired deleted/added lines), an *Ignore whitespace* toggle (`git diff -w`; staging is switched off while it is on because the hunks no longer match the file), a *Show whole file* toggle, long runs of unchanged lines fold into a clickable "N unchanged lines" row, and image files (PNG, JPEG, GIF, WebP, BMP, TIFF, HEIC, ICO) show a before/after preview with size and dimensions.
- Open in Finder, Terminal and editor: a toolbar menu, Repository menu items (⌥⌘T terminal, ⌥⌘E editor, ⇧⌥⌘R Finder) and ⌘K entries open the repository root. The editor application is set in Settings > Tools.
- Custom actions: define named shell commands in Settings > Tools. They run with `/bin/sh -c` in the repository root with `GITSYNC_REPO` and `GITSYNC_BRANCH` in the environment (never substituted into the command), and are listed in the toolbar menu, the Repository menu and the palette. A failing action shows its exit code and output.
- Home screen pinning and groups: right-click a repository on the home screen to pin it or add it to a named group. Pinned repositories and groups get their own sections above Recent; groups can be created, renamed and deleted, and repositories removed from home. Layout is saved and paths that no longer exist are dropped.
- Dock integration: the Dock icon shows a badge with the number of files with uncommitted changes across all open repositories (capped at 99+), right-clicking it lists recent repositories, and File > Open Recent lists them in the menu bar with Clear Menu.
- Profile pictures: commit authors in history, commit details and file history, and comment authors on pull requests and issues, show their picture from the hosting platform (GitHub, GitLab, Gitea, Bitbucket Cloud), over their initials until it loads. Only the repository's own platform is asked; no Gravatar or other third party. Pictures are cached for a week.
- Tag icons: sidebar tags get an icon from their name: a star for major releases (`v2.0.0`), a tag for other versions (outlined when the tag is lightweight), a flag for release candidates, a test tube for alpha/beta/preview, a moon for nightly, a seal for `latest`/`stable`, a shield for LTS, a paper plane for deploy markers and a box for backups. The tag chips in the history list use the same icons.
- Branch icons: sidebar branches (local and remote) get an icon chosen from the name: a star for `main`/`master`, a hammer for `develop`, sparkles for `feature/…`, a bug for `fix/…`, a flame for `hotfix/…`, a box for `release/…`, plus `docs`, `test`, `refactor`, `perf`, `chore`, `wip`, `dependabot`, `pr/…` and issue-number branches. The current branch keeps a small green check. The branch chips in the history list use the same icons and colours (remote branches by the name after the remote), and so does the toolbar branch picker.
- Folder icons: the folder that holds a changed file gets a coloured folder icon by name (`src`, `docs`, `tests`, `assets`, `components`, `scripts`, `config`, `.github`, `node_modules`, `dist`, and more), in the changed-files lists, the diff header and the worktrees list. Files inside `node_modules`, `.github`, `dist` and similar keep that folder's look.
- File type icons: every file shows a flat, coloured icon for its type, like the VS Code Material icons: the React atom for `.tsx` and `.jsx`, brand tiles for TypeScript, JavaScript, Python, Go, Rust, Java, Kotlin, Vue, Svelte, HTML, CSS, JSON, Markdown, npm and more, and symbols for Swift, Docker, Git files, images, video, audio, archives, PDFs, lockfiles, scripts and databases. Shown in the changed-files lists, the diff header and file history; hover for the type name.
- Large repositories: when loading history takes over half a second, GitSync writes git's commit-graph cache once in the background (only a cache under `.git`). On a 100,000-commit repository history loads in about 0.015s instead of 0.4s. History was already paged ("Load More").
- Clone options: an Advanced section in the clone sheet for shallow clones (latest N commits), blobless or treeless filters, a single branch, and submodules. Shallow clones show a banner with "Fetch Full History".
- Git LFS: files stored with LFS (from `.gitattributes`) get an LFS badge in the changed-files list. Works without git-lfs installed.
- Worktrees and submodules: "Worktrees & Submodules…" lists, adds, opens and removes worktrees, and lists submodules with their state, with Initialize, Update All, Update to Latest, Open and Add.
- Patches: export a commit as a `.patch` file, save your uncommitted changes as a patch, and apply patch files to the working tree, to the index, or as commits with author and message kept (`git am`, with a continue/skip/abort banner on conflicts).
- Bisect: right-click commits to mark a bad and a good one, then mark each commit git picks as Good, Bad or Skip from a banner until it names the first bad commit.
- Pull and push options: right-click Pull for merge, rebase or fast-forward only; right-click Push for push with tags, force push with lease (always confirmed) and push to another remote. A rejected push offers to pull first or force push with lease; a diverged fast-forward-only pull says so plainly.
- Remotes: "Manage Remotes…" lists remotes with their URLs (passwords redacted) and adds, renames, changes the URL of or removes them, with fetch and push per remote. URLs with embedded passwords are refused.
- Fork: "Fork Repository…" forks the current repository on GitHub, GitLab, Gitea or Bitbucket Cloud with your connected account, then either makes the fork `origin` and the original `upstream`, or adds it as another remote, and fetches it.
- Notifications: review requests, mentions and assignments from your GitHub, GitLab and Gitea accounts, with a bell and unread count in the toolbar (refreshed every 5 minutes), a list that opens the item on the web and marks it read, and Mark All as Read.
- CI status: a checks summary ("All 38 checks passed", "2 of 9 checks failed") with an expandable list and links to each run, on the selected commit and on pull requests (GitHub check runs and statuses, GitLab pipeline jobs, Gitea and Bitbucket Cloud statuses). Works for public repositories without an account.
- Pull request and issue actions: create a pull/merge request from the current branch (title and base picker, draft, pushes the branch first), create issues, read and add comments, merge (merge commit, squash or rebase, with confirmation), close and reopen, and edit labels. GitHub, GitLab and Gitea; Bitbucket Cloud for pull requests. Needs a connected account; the server's own error text is shown when a request is rejected.
- Commit message helpers: a menu beside the commit box with a conventional-commit type picker (plus scopes taken from the staged folders), an issue reference picker (Closes or Refs, from your open issues), your `commit.template`, reuse of recent messages, and spell checking while typing (on by default, can be turned off).
- Ignore helper: right-click a changed file, then Ignore, to ignore that file, any file with its name, all files with its extension, or its folder; written to `.gitignore` or, with "Only on This Machine", to `.git/info/exclude`. Already-tracked files are untracked (kept on disk) so the rule takes effect.
- Hook output: when a pre-commit, prepare-commit-msg or commit-msg hook rejects a commit, a panel shows everything the hook printed (colour codes stripped), keeps your message, and offers Copy Output and "Commit Without Hooks" (`--no-verify`).
- History search: search all history (not just loaded commits) by message or author, find commits that add or remove a piece of code (pickaxe) or match a regex in their diff, and limit by file or folder and by date range.
- Tag tools: annotated tags (a message makes the tag annotated), push a tag or all tags, delete a tag on the remote, optional push when creating; the sidebar tooltip shows the tag message.
- Branch tools: rename a branch, choose or clear its tracking branch, delete a branch on the remote (with confirmation), and "Clean Up Branches…" listing local branches that are merged or whose remote branch is gone (unmerged ones are flagged).
- Compare any two refs (branches, tags, commits): ahead/behind, the commits, the changed files and a diff for each, optionally only the changes since the common ancestor.
- Blame and file history: per-line authorship (click a line's author to jump to the commit) and a "history of this file" list with the diff of each commit, following renames.
- Pull request and issue descriptions render as Markdown (headings, lists, task lists, quotes, code blocks, rules, inline styling).
- Commit signing: GPG, SSH and X.509 signature badges in commit details (verified, untrusted, unverifiable, bad, expired, revoked), and a Sign checkbox in the commit box that follows `commit.gpgsign` and `user.signingkey`.
- Discard and stash safety: discard confirmations state exactly what is lost (files, lines added/removed, untracked files and size); stash a single hunk; preview a stash (files and diffs) before applying; applying a stash into a file with other local changes falls back to a patch when it can.
- Rebase: interactive rebase editor (reorder by dragging; pick, reword, squash, fixup, drop) from the history menu, "Rebase Current Branch onto This" from branches, and a Pull strategy setting (merge or rebase). Conflicts stop the rebase in the operation banner.
- Reset and undo: Reset Branch to Here (soft, mixed, hard) from the history menu, a Reflog browser (reset, checkout or branch from any earlier HEAD), and Undo Last Change.
- Conflict resolution UI: per-conflict Ours / Theirs / Both choices with side-by-side previews, All Ours / All Theirs, Mark as Resolved (saves and stages); whole-file Keep Ours / Keep Theirs / Delete for delete-modify and binary conflicts.
- In-progress operation banner: detects a merge, rebase, cherry-pick or revert in progress (including a sequence of picks) and offers Continue, Skip and Abort, plus palette commands.
- Hosting provider accounts (GitHub, GitLab, Bitbucket, Gitea/Forgejo/Codeberg, Azure DevOps, including self-hosted) with tokens in the Keychain; authenticated fetch, pull, push and clone for private repositories via `GIT_ASKPASS` (secrets never appear in URLs or config).
- Enterprise and self-managed servers: GitHub Enterprise (Server and ghe.com), GitLab self-managed, Gitea/Forgejo, Bitbucket Data Center; custom ports and http; sign in with a token or a username and password.
- Pull request / merge request and issue lists (GitHub, GitLab, Gitea; Bitbucket Cloud pull requests) with open/closed/all filters, search, paging, details, check out branch and open on web. Public repositories work without an account.
- OAuth browser sign-in: GitHub device flow, GitLab, Gitea and Azure DevOps (Microsoft Entra) authorization code with PKCE (public clients, no secret shipped), Bitbucket Cloud with your own consumer key and secret; tokens refresh automatically.
- Browse and clone repositories from a connected account; "Open on <provider>" links for repository, branch, pull/merge request and commit.
- Hunk and line staging, unstaging and discarding (`PatchBuilder` + `git apply`).
- Multi-repository workspace with a repo rail, persisted across launches.
- ⌘K command palette; frameless window with floating panels and resizable columns.
- `--open=/path` launch flag.
- Initial macOS app (SwiftUI): history with branch graph, working-copy staging and commit,
  branches / remotes / tags / stashes sidebar, fetch / pull / push, live repository watching.
- `GitSyncCore` engine with parsers, graph layout and tests.

### Fixed

- Many Git calls running at once could deadlock and freeze the app or hang the tests.
