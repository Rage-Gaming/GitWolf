using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfApp/Accounts.swift. It lives in the engine so it can be tested.

/// <summary>Where secrets are kept. On Windows this is Credential Manager.</summary>
public interface ISecretStore
{
    /// <summary>Saves or replaces the secret; throws <see cref="SecretStoreException"/> if it can't.</summary>
    void Save(string account, string secret);
    string? Read(string account);
    void Delete(string account);
}

public sealed class SecretStoreException(string message) : Exception(message);

/// <summary>
/// Saved accounts: their metadata in a JSON file, their secrets only in the credential store. Safe to
/// use from any thread, so git operations running in the background can look credentials up.
/// </summary>
public sealed class AccountStore
{
    private sealed record Entry(
        string Id, string Kind, string Host, string Username,
        bool UsesPassword = false, string? Scheme = null, string? OAuthClientId = null);

    private sealed record Document(List<Entry>? Accounts = null, Dictionary<string, string>? ClientIds = null);

    private readonly string _path;
    private readonly ISecretStore _secrets;
    private readonly Func<ProviderAccount, OAuthTokens, Task<OAuthTokens>> _refresh;
    private readonly object _lock = new();
    private readonly Dictionary<string, SemaphoreSlim> _refreshing = [];
    private List<ProviderAccount> _accounts;
    private readonly Dictionary<string, string> _clientIds;

    public AccountStore(string path, ISecretStore secrets,
        Func<ProviderAccount, OAuthTokens, Task<OAuthTokens>>? refresh = null)
    {
        _path = path;
        _secrets = secrets;
        _refresh = refresh ?? ((account, tokens) => new OAuthClient(
            account.Kind, account.Origin, account.OAuthClientId!, tokens.ClientSecret).RefreshAsync(tokens));
        var document = Load(path);
        _accounts = (document.Accounts ?? []).Select(Account).OfType<ProviderAccount>().ToList();
        _clientIds = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (host, id) in document.ClientIds ?? []) _clientIds[host] = id;
    }

    /// <summary>Raised after an account was added or removed, on the thread that did it.</summary>
    public event Action? Changed;

    public IReadOnlyList<ProviderAccount> Accounts
    {
        get { lock (_lock) return _accounts; }
    }

    /// <summary>Only an account the user added: a host is never matched by guessing.</summary>
    public ProviderAccount? ForHost(string host) =>
        Accounts.FirstOrDefault(a => a.HostName.Equals(host, StringComparison.OrdinalIgnoreCase));

    /// <summary>Saves (or replaces) an account and its secret.</summary>
    public void Add(ProviderAccount account, string secret)
    {
        lock (_lock)
        {
            var replaced = _accounts.Where(a => a.Id != account.Id && a.Kind == account.Kind
                && a.Host == account.Host && a.Username == account.Username).ToList();
            var next = _accounts.Where(a => a.Id != account.Id && !replaced.Contains(a)).Append(account).ToList();
            // The secret first: an account without one would be useless.
            _secrets.Save(account.Id, secret);
            try
            {
                Write(next);
            }
            catch (SecretStoreException)
            {
                _secrets.Delete(account.Id);
                throw;
            }
            _accounts = next;
            foreach (var old in replaced) _secrets.Delete(old.Id);
        }
        Changed?.Invoke();
    }

    public void AddOAuth(ProviderAccount account, OAuthTokens tokens) => Add(account, tokens.ToJson());

    public void Remove(ProviderAccount account)
    {
        lock (_lock)
        {
            var next = _accounts.Where(a => a.Id != account.Id).ToList();
            _secrets.Delete(account.Id);
            _accounts = next;
            Write(next);
        }
        Changed?.Invoke();
    }

    /// <summary>A client ID the user typed for this host. Client IDs are public, not secrets.</summary>
    public string? ClientId(string host)
    {
        lock (_lock) return _clientIds.GetValueOrDefault(host);
    }

    public void RememberClientId(string host, string clientId)
    {
        lock (_lock)
        {
            _clientIds[host] = clientId;
            Write(_accounts);
        }
    }

    /// <summary>
    /// The secret to use right now: a token or password as stored or, for OAuth accounts, a valid access
    /// token (refreshed first when it is about to expire).
    /// </summary>
    public async Task<string?> SecretAsync(ProviderAccount account)
    {
        var stored = _secrets.Read(account.Id);
        if (stored is null || !account.UsesOAuth) return stored;
        if (OAuthTokens.FromJson(stored) is not { } tokens) return null;
        if (!tokens.NeedsRefresh()) return tokens.AccessToken;

        SemaphoreSlim? gate;
        lock (_lock)
        {
            if (!_refreshing.TryGetValue(account.Id, out gate)) _refreshing[account.Id] = gate = new SemaphoreSlim(1, 1);
        }
        // One at a time per account: two refreshes would race on a rotating refresh token.
        await gate.WaitAsync().ConfigureAwait(false);
        try
        {
            // Whoever held the gate may already have refreshed.
            if (_secrets.Read(account.Id) is not { } current || OAuthTokens.FromJson(current) is not { } latest) return null;
            if (!latest.NeedsRefresh()) return latest.AccessToken;
            try
            {
                var fresh = await _refresh(account, latest).ConfigureAwait(false);
                lock (_lock)
                {
                    // An account removed meanwhile must not come back.
                    if (_accounts.Any(a => a.Id == account.Id)) _secrets.Save(account.Id, fresh.ToJson());
                }
                return fresh.AccessToken;
            }
            catch (Exception e) when (e is OAuthException or SecretStoreException or HttpRequestException)
            {
                // The old token may still work; if not, the server says so.
                Trace.TraceWarning($"Refreshing a sign-in failed: {e.GetType().Name}");
                return latest.AccessToken;
            }
        }
        finally
        {
            gate.Release();
        }
    }

    /// <summary>
    /// The credential git should use for a remote on `authority` (`host[:port]`, as
    /// <see cref="GitCredential.HttpAuthority"/> gives it), if the user added an account for exactly that.
    /// </summary>
    public async Task<GitCredential?> CredentialForRemoteAsync(string authority)
    {
        var account = Accounts.FirstOrDefault(a =>
            GitCredential.HttpAuthority(a.Origin)?.Equals(authority, StringComparison.OrdinalIgnoreCase) == true);
        if (account is null || await SecretAsync(account).ConfigureAwait(false) is not { } secret) return null;
        var user = account.UsesOAuth ? GitCredential.OAuthUsername(account.Kind, account.Username) : account.Username;
        return new GitCredential(authority, user, secret)
        {
            Scheme = account.Scheme ?? "https",
            UseBearerHeader = account.UsesOAuth && account.Kind == ProviderKind.Azure,
        };
    }

    /// <summary>
    /// Writes the `GIT_ASKPASS` helper (LF endings, no BOM) if it is missing or differs, and returns its
    /// path; null when it can't be written. The script holds no secret.
    /// </summary>
    public static string? WriteAskpass(string directory)
    {
        try
        {
            var path = Path.Combine(directory, GitCredential.AskpassScriptFileName);
            var content = Encoding.UTF8.GetBytes(GitCredential.AskpassScript);
            if (File.Exists(path) && File.ReadAllBytes(path).AsSpan().SequenceEqual(content)) return path;
            Directory.CreateDirectory(directory);
            File.WriteAllBytes(path, content);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            return path;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"The sign-in helper could not be written: {e.GetType().Name}");
            return null;
        }
    }

    /// <summary>Null for entries that were damaged or edited into something unusable.</summary>
    private static ProviderAccount? Account(Entry e)
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
            if (kind.Id() == e.Kind && !string.IsNullOrEmpty(e.Id) && ProviderAccount.CleanHost(e.Host ?? "")?.Host == e.Host)
                return new ProviderAccount(kind, e.Host!, e.Username ?? "", e.UsesPassword, e.Scheme, e.Id, e.OAuthClientId);
        return null;
    }

    private static Document Load(string path)
    {
        try
        {
            return File.Exists(path) ? JsonSerializer.Deserialize<Document>(File.ReadAllText(path)) ?? new() : new();
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Accounts could not be read: {e.GetType().Name}");
            return new();
        }
    }

    private void Write(List<ProviderAccount> accounts)
    {
        var document = new Document(
            accounts.Select(a => new Entry(a.Id, a.Kind.Id(), a.Host, a.Username, a.UsesPassword == true,
                a.Scheme, a.OAuthClientId)).ToList(),
            _clientIds);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            // Write then rename, so a crash can't leave a half-written file.
            var temporary = _path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(document));
            File.Move(temporary, _path, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Accounts could not be saved: {e.GetType().Name}");
            throw new SecretStoreException("The account couldn’t be saved on this computer.");
        }
    }
}
