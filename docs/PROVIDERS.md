# Hosting providers

Spec for provider accounts. Reference code: `apple/Sources/GitSyncCore/Providers.swift`,
`ProviderClient.swift` (portable logic, tested with stub transports) and
`apple/Sources/GitSyncApp/Accounts.swift` (macOS-only storage).

## Account model

```
ProviderAccount { id, kind, host, username, usesPassword?, scheme? }
```

- `kind`: `github | gitlab | bitbucket | gitea | azure`.
- `host`: server name, optionally with `:port` and a path (GitLab under a sub-path). Default hosts:
  github.com, gitlab.com, bitbucket.org, codeberg.org (Gitea), dev.azure.com.
- `scheme`: `"http"` for servers without TLS, otherwise https.
- `usesPassword`: secret is an account password (HTTP Basic) instead of a token.
- `hostName` (host without port/path) is what Git remotes are matched against.
- Metadata is stored as JSON in app preferences; **the secret is stored only in the OS credential
  store**, keyed by `account.id`.
- Guessing the kind from a typed host (`gitlab.acme.com` → GitLab) is `ProviderKind.guess`.

## Authenticating Git (all platforms)

Never put secrets in URLs, command lines or config files. Use `GIT_ASKPASS`:

1. Write a tiny helper script/exe that prints `$GITSYNC_ASKPASS_USER` when git asks for a username
   and `$GITSYNC_ASKPASS_TOKEN` otherwise (`GitCredential.askpassScript`; on Windows use a `.cmd`
   or a small exe that does the same).
2. For fetch / pull / push / clone, find the account whose `hostName` equals the host of the
   `origin` remote (else the first remote) and run git with
   `GIT_ASKPASS=<helper>`, `GITSYNC_ASKPASS_USER`, `GITSYNC_ASKPASS_TOKEN`,
   `GIT_CONFIG_COUNT=1`, `GIT_CONFIG_KEY_0=credential.helper`, `GIT_CONFIG_VALUE_0=` (empty) so a
   stale system credential helper cannot interfere. `GIT_TERMINAL_PROMPT=0` stays set.
3. No matching account → run git normally (user's own helpers/SSH keys keep working).

This was verified against a local HTTP server: git sends the first request unauthenticated, gets a
401, then retries with `Authorization: Basic base64(user:token)`.

## OAuth sign-in (browser)

Reference: `apple/Sources/GitSyncCore/OAuth.swift` (portable; uses SHA-256 for PKCE) and
`apple/Sources/GitSyncApp/OAuthSignIn.swift` (loopback listener, session driver).

Only **public-client** flows are used, so GitSync never needs (or ships) a client secret:

| Provider | Flow | Endpoints (`<origin>` = scheme + host) |
|---|---|---|
| GitHub (and Enterprise) | Device flow | `POST <origin>/login/device/code`, poll `POST <origin>/login/oauth/access_token` (`grant_type=urn:ietf:params:oauth:grant-type:device_code`); handle `authorization_pending`, `slow_down` (+5 s), `access_denied`, `expired_token` |
| GitLab (and self-managed) | Authorization code + PKCE (S256), loopback redirect | `<origin>/oauth/authorize`, `<origin>/oauth/token` |
| Gitea / Forgejo / Codeberg | Authorization code + PKCE, loopback redirect | `<origin>/login/oauth/authorize`, `<origin>/login/oauth/access_token` |
| Bitbucket Cloud | Authorization code, **no PKCE, needs the consumer secret** | authorize `https://bitbucket.org/site/oauth2/authorize`; token `POST https://bitbucket.org/site/oauth2/access_token` with HTTP Basic `client_id:secret`. The user registers their own *private consumer* (callback URL = loopback URI) and enters Key + Secret; the secret is stored with the tokens in the credential store and never bundled. Tokens last 2 h and refresh. Data Center: not offered. |
| Azure DevOps | Authorization code + PKCE via Microsoft Entra | `https://login.microsoftonline.com/organizations/oauth2/v2.0/{authorize,token}`, scope `499b84ac-1321-427f-aa17-267ca6975798/user_impersonation offline_access` (sent on refresh too), `response_mode=query`. Public client: register a "Mobile and desktop" redirect URI and allow public client flows. Signed-in user from `GET https://app.vssps.visualstudio.com/_apis/profile/profiles/me?api-version=7.1`. |

- **Loopback redirect** is fixed: `http://127.0.0.1:53682/callback` (`OAuthLoopback`). GitLab and
  Gitea require the exact redirect URI to be registered. Listen on the loopback interface only,
  verify `state`, answer with a small "you can close this tab" page, time out after 5 minutes.
- **Client IDs.** A client ID is public but belongs to an application registered on a host. GitSync
  ships none by default (`OAuthClients.builtIn` is empty; maintainers add IDs for github.com,
  gitlab.com, codeberg.org). Otherwise the user pastes their own client ID, remembered per host, with
  an inline hint on how to register the app (public client, redirect URI, scopes: GitHub `repo`;
  GitLab `read_api read_repository write_repository`).
- **Storage.** The credential-store secret for an OAuth account is a JSON `OAuthTokens`
  `{accessToken, refreshToken?, expiresAt?}`; the account carries `oauthClientID`.
- **Refresh.** Before any network git command or API call, if the access token expires within a
  minute, refresh it (`grant_type=refresh_token`), keep the old refresh token if none is returned,
  and write the new tokens back. Serialise refreshes per account (rotating refresh tokens break if two
  run at once). GitHub OAuth-app tokens do not expire; GitLab's last 2 hours.
- **Using the token.** API: `Authorization: Bearer <access>` for every provider. Git: through
  `GIT_ASKPASS` with username `oauth2` for GitLab, `x-access-token` for GitHub, `x-token-auth` for
  Bitbucket, the real username otherwise. **Azure DevOps** Entra tokens are sent as
  `Authorization: Bearer` through `http.extraheader` set with `GIT_CONFIG_COUNT/KEY_1/VALUE_1`
  (environment only, never the command line).

## API usage (listing + verification)

| Kind | API base | Auth header | List repos |
|---|---|---|---|
| GitHub | `https://api.github.com` · Enterprise Server `<origin>/api/v3` · `*.ghe.com` → `https://api.<host>` | `Bearer` | `GET /user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member&page=N` |
| GitLab | `<origin>/api/v4` | `PRIVATE-TOKEN` | `GET /projects?membership=true&simple=true&per_page=100&order_by=last_activity_at&page=N` |
| Gitea / Forgejo | `<origin>/api/v1` | `Authorization: token …` | `GET /user/repos?limit=50&page=N` |
| Bitbucket Cloud | `https://api.bitbucket.org/2.0` | Basic (username + app password) | `GET /repositories?role=member&pagelen=100`, follow `next` |
| Bitbucket Data Center | `<origin>/rest/api/1.0` | `Bearer` (HTTP access token) | `GET /repos?limit=100&start=N`, follow `nextPageStart` |
| Azure DevOps | n/a | n/a | not supported; paste a URL |

`usesPassword` accounts always send HTTP Basic. Pagination is capped (5 pages) to stay fast.
Verification calls `GET /user` (Bitbucket DC lists one repo; Azure is not verified). GitHub and
GitLab reject passwords on their APIs, so a password account that fails verification there is still
saved (Git may accept it).

Parsers are pure functions over JSON (`parseGitHub`, `parseGitLab`, `parseGitea`, `parseBitbucket`,
`parseBitbucketServer`); port them with the fixtures in `ProviderTests`. Bitbucket puts the username
into https clone URLs; strip it so our credential is used.

## Pull requests and issues

Reference: end of `ProviderClient.swift` (`CollabItem`, `ProviderClient.collab`, `parse*Collab`),
`apple/Sources/GitSyncApp/Collab.swift` (state) and `Views/CollabViews.swift` (UI). Page size 30,
1-based `page`. Normalised model: number, title, author, state (open/closed/merged), draft, labels,
comment count, created/updated, web URL, body, source/target branch.

| Kind | Pull requests | Issues |
|---|---|---|
| GitHub | `GET /repos/{o}/{r}/pulls?state=open\|closed\|all&sort=updated&direction=desc` (merged = `merged_at` set) | `GET /repos/{o}/{r}/issues?state=…`; **drop items that have a `pull_request` key** |
| GitLab | `GET /projects/{url-encoded path}/merge_requests?state=opened\|closed\|merged\|all&order_by=updated_at` (the *Closed* filter calls `closed` and `merged`, merges the lists by date) | `…/issues?state=opened\|closed\|all` |
| Gitea | `GET /repos/{o}/{r}/pulls?state=…&sort=recentupdate&limit=30` (`merged` bool; draft = `WIP:`/`Draft:` title prefix) | `GET /repos/{o}/{r}/issues?type=issues&state=…` |
| Bitbucket Cloud | `GET /repositories/{w}/{r}/pullrequests?state=OPEN` (closed = `MERGED`+`DECLINED`) | not offered (issue tracker is optional) |
| Bitbucket DC, Azure | not offered | not offered |

With no account for the host, send the request without an `Authorization` header (public data).

### Notifications

| Provider | List | Mark read | Mark all |
|---|---|---|---|
| GitHub | `GET /notifications?participating=true` (needs the `notifications` or `repo` scope; `reason`: `review_requested`, `mention`/`team_mention`, `assign`, other → Activity). `subject.url` is an API URL: `…/repos/o/r/pulls/12` → `/o/r/pull/12`, `issues/7` → `/o/r/issues/7`, `commits/<sha>` → `/o/r/commit/<sha>` | `PATCH /notifications/threads/{id}` | `PUT /notifications` |
| GitLab | `GET /todos?state=pending` (`action_name`: `review_requested`, `mentioned`/`directly_addressed`, `assigned`; `target_url` is the web URL) | `POST /todos/{id}/mark_as_done` | `POST /todos/mark_as_done` |
| Gitea | `GET /notifications?status-types=unread` (`subject.html_url`; no reason, shown as Activity) | `PATCH /notifications/threads/{id}` | `PUT /notifications` |

### CI checks

`GET` per commit SHA (only hex SHAs are sent):

| Provider | Endpoint | State mapping |
|---|---|---|
| GitHub | `/repos/{o}/{r}/commits/{sha}/check-runs` plus the legacy `/commits/{sha}/status` | `status != completed` → pending; `success` → success; `skipped`/`neutral` → neutral; `failure`, `cancelled`, `timed_out`, `action_required`… → failure |
| GitLab | `/projects/:id/repository/commits/{sha}/statuses` | `success`; `failed`/`canceled` → failure; `running`/`pending`/`created`/`manual` → pending |
| Gitea | `/repos/{o}/{r}/commits/{sha}/status` (`statuses[]`) | same words as GitHub statuses |
| Bitbucket Cloud | `/repositories/{w}/{r}/commit/{sha}/statuses` | `SUCCESSFUL`, `FAILED`/`STOPPED`, `INPROGRESS` |

The same name reported twice (re-runs) keeps the first entry. Azure DevOps and Bitbucket Server are not supported.

### Write calls

All send JSON with the same auth headers; non-2xx replies surface the body's `message` / `error` (plus GitHub's `errors[].message`) so users see why (e.g. "A pull request already exists").

| Action | GitHub | GitLab (`:id` = url-encoded path) | Gitea | Bitbucket Cloud |
|---|---|---|---|---|
| Create PR | `POST /repos/{o}/{r}/pulls` `{title, body, head, base, draft}` | `POST /projects/:id/merge_requests` `{title ("Draft: " prefix), description, source_branch, target_branch}` | `POST /repos/{o}/{r}/pulls` (draft = `WIP:` prefix) | `POST /repositories/{w}/{r}/pullrequests` `{title, description, source.branch.name, destination.branch.name}` |
| Create issue | `POST /repos/{o}/{r}/issues` | `POST /projects/:id/issues` | `POST /repos/{o}/{r}/issues` | n/a |
| Comments | `GET/POST /repos/{o}/{r}/issues/{n}/comments` | `GET/POST …/{merge_requests\|issues}/{n}/notes` (skip `system`) | same as GitHub | `GET/POST …/pullrequests/{n}/comments` `{content:{raw}}` |
| Merge | `PUT …/pulls/{n}/merge` `{merge_method}` | `PUT …/merge_requests/{n}/merge` `{squash}` | `POST …/pulls/{n}/merge` `{Do}` | `POST …/pullrequests/{n}/merge` `{merge_strategy}` |
| Close / reopen | `PATCH …/{pulls\|issues}/{n}` `{state}` | `PUT …` `{state_event: close\|reopen}` | `PATCH …` `{state}` | `POST …/decline` (no reopen) |
| Labels | `PUT …/issues/{n}/labels` | `PUT …` `{labels: "a,b"}` | not supported (ids) | n/a |

## Remote URL parsing and web links

`RemoteLocation.parse` handles `https://`, `http://`, `ssh://`, `git://`, scp-style
`git@host:owner/repo.git`, strips `user@`, port and `.git`, lower-cases the host, and converts
Azure's `ssh.dev.azure.com:v3/org/project/repo` to `dev.azure.com/org/project/_git/repo`. Local
paths return nothing.

`WebLinks` builds URLs from `kind` + location:

| | repository | branch | new PR/MR | commit |
|---|---|---|---|---|
| GitHub | `/o/r` | `/tree/<b>` | `/compare/<b>?expand=1` | `/commit/<h>` |
| GitLab | `/o/r` | `/-/tree/<b>` | `/-/merge_requests/new?merge_request[source_branch]=<b>` | `/-/commit/<h>` |
| Bitbucket | `/o/r` | `/src/<b>` | `/pull-requests/new?source=<b>` | `/commits/<h>` |
| Gitea | `/o/r` | `/src/branch/<b>` | `/pulls` | `/commit/<h>` |
| Azure | `/org/p/_git/r` | `?version=GB<b>` | `/pullrequestcreate?sourceRef=<b>` | `/commit/<h>` |

(Gitea's link opens the pull request list. Check `Providers.swift` for the exact strings; Bitbucket Data Center uses a different layout and is
not handled yet.)

## UI

Settings → Accounts lists accounts (flat brand tile, `@user · host`, Remove with confirmation).
Add Account: provider tiles, a *Token* / *Username & password* switch, host (with a hint for
enterprise servers), username (when needed), secret field, "create a token" link with the scope
hint, inline verification errors. Brand marks are Simple Icons (CC0) in
`apple/Sources/GitSyncApp/ProviderLogos.swift`; on a light tile/dark tile choose the contrasting
colour (GitHub's mark is black).
