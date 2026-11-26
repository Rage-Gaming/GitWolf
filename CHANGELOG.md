# Changelog

All notable changes are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
