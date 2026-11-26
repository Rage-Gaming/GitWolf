# Changelog

All notable changes are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
