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
| Bitbucket, Azure DevOps | not offered | Bitbucket Cloud needs a client secret; Azure needs Microsoft Entra. Use tokens. |

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
  `GIT_ASKPASS` with username `oauth2` for GitLab, `x-access-token` for GitHub, the real username
  otherwise.

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
