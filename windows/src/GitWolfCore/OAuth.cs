using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/OAuth.swift.

/// <summary>Tokens returned by an OAuth server. <see cref="ExpiresAt"/> is null for tokens that never expire.</summary>
public sealed record OAuthTokens(
    string AccessToken, string? RefreshToken = null, DateTimeOffset? ExpiresAt = null,
    // Bitbucket Cloud needs its consumer secret to refresh, so it is kept with the tokens, in the credential store.
    string? ClientSecret = null)
{
    /// <summary>True when the access token should be refreshed before use (with a minute of slack).</summary>
    public bool NeedsRefresh(DateTimeOffset? now = null) =>
        ExpiresAt is { } expires && expires - (now ?? DateTimeOffset.UtcNow) < TimeSpan.FromSeconds(60);

    /// <summary>Never print the tokens.</summary>
    public override string ToString() => "OAuthTokens";

    public string ToJson() => JsonSerializer.Serialize(this);

    public static OAuthTokens? FromJson(string json)
    {
        try
        {
            var tokens = JsonSerializer.Deserialize<OAuthTokens>(json);
            return string.IsNullOrEmpty(tokens?.AccessToken) ? null : tokens;
        }
        catch (JsonException)
        {
            return null;
        }
    }
}

public enum OAuthFlow { Device, Pkce }

public sealed record DeviceCode(string Code, string UserCode, Uri VerificationUrl, int Interval, int ExpiresIn);

public sealed class OAuthException(string message) : Exception(message)
{
    public static OAuthException Denied => new("Sign-in was denied.");
    public static OAuthException Expired => new("The sign-in expired. Try again.");
    public static OAuthException InvalidResponse => new("The server sent an unexpected response.");
}

public static class OAuthProviderExtensions
{
    public static OAuthFlow Flow(this ProviderKind kind) => kind == ProviderKind.GitHub ? OAuthFlow.Device : OAuthFlow.Pkce;

    /// <summary>OAuth is offered for Bitbucket Cloud only (Data Center uses access tokens).</summary>
    public static bool SupportsOAuth(this ProviderKind kind, string host) =>
        kind != ProviderKind.Bitbucket || host == "bitbucket.org";

    /// <summary>Bitbucket Cloud's authorization-code grant has no PKCE and requires the consumer's secret.</summary>
    public static bool OAuthNeedsClientSecret(this ProviderKind kind) => kind == ProviderKind.Bitbucket;

    public static bool OAuthUsesPkce(this ProviderKind kind) => kind != ProviderKind.Bitbucket;

    public static string OAuthScopes(this ProviderKind kind) => kind switch
    {
        ProviderKind.GitHub => "repo",
        ProviderKind.GitLab => "read_api read_repository write_repository",
        // Azure DevOps resource id (user_impersonation) plus a refresh token.
        ProviderKind.Azure => "499b84ac-1321-427f-aa17-267ca6975798/user_impersonation offline_access",
        _ => "",
    };

    /// <summary>What to enter when registering an application on the provider.</summary>
    public static string OAuthSetupHint(this ProviderKind kind, string host) => kind switch
    {
        ProviderKind.GitHub => $"On {host}: Settings → Developer settings → OAuth Apps → New. Tick “Enable Device Flow”, then paste the Client ID.",
        ProviderKind.GitLab => $"On {host}: Preferences → Applications. Redirect URI {OAuthLoopback.RedirectUri}, untick “Confidential”, scopes read_api, read_repository, write_repository.",
        ProviderKind.Gitea => $"On {host}: Settings → Applications → Manage OAuth2 applications. Redirect URI {OAuthLoopback.RedirectUri}, untick “Confidential client”.",
        ProviderKind.Bitbucket => $"On bitbucket.org: Workspace settings → OAuth consumers → Add consumer. Callback URL {OAuthLoopback.RedirectUri}, tick “This is a private consumer”, permissions Account (read), Repositories (read, write), Pull requests (read). Paste the Key here and the Secret below.",
        ProviderKind.Azure => $"In the Microsoft Entra admin center: App registrations → New registration. Add a “Mobile and desktop applications” redirect URI {OAuthLoopback.RedirectUri}, turn on “Allow public client flows”, and under API permissions add Azure DevOps → user_impersonation. Paste the Application (client) ID.",
        _ => throw new ArgumentOutOfRangeException(nameof(kind)),
    };
}

public sealed record Pkce(string Verifier, string Challenge)
{
    public static Pkce Generate()
    {
        var verifier = Base64Url(RandomNumberGenerator.GetBytes(32));
        return new Pkce(verifier, ChallengeFor(verifier));
    }

    public static string ChallengeFor(string verifier) => Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(verifier)));

    /// <summary>An unguessable value tying the browser's answer to this request.</summary>
    public static string NewState() => Base64Url(RandomNumberGenerator.GetBytes(24));

    private static string Base64Url(byte[] data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

public sealed class OAuthClient(
    ProviderKind kind, string origin, string clientId, string? clientSecret = null,
    HttpTransport? transport = null, Func<int, CancellationToken, Task>? sleep = null)
{
    /// <summary>Microsoft Entra tenant used for Azure DevOps (work and school accounts).</summary>
    private const string AzureAuthority = "https://login.microsoftonline.com/organizations/oauth2/v2.0";

    private readonly HttpTransport _transport = transport ?? ProviderClient.HttpClientTransport;
    private readonly Func<int, CancellationToken, Task> _sleep =
        sleep ?? ((seconds, token) => Task.Delay(TimeSpan.FromSeconds(seconds), token));

    private string AuthorizeUrl => kind switch
    {
        ProviderKind.Gitea => $"{origin}/login/oauth/authorize",
        ProviderKind.Bitbucket => "https://bitbucket.org/site/oauth2/authorize",
        ProviderKind.Azure => $"{AzureAuthority}/authorize",
        _ => $"{origin}/oauth/authorize",
    };

    private string TokenUrl => kind switch
    {
        ProviderKind.Gitea or ProviderKind.GitHub => $"{origin}/login/oauth/access_token",
        ProviderKind.Bitbucket => "https://bitbucket.org/site/oauth2/access_token",
        ProviderKind.Azure => $"{AzureAuthority}/token",
        _ => $"{origin}/oauth/token",
    };

    private string DeviceUrl => $"{origin}/login/device/code";

    // MARK: Authorization code + PKCE

    public Uri? AuthorizationUrl(string redirectUri, string state, string challenge)
    {
        var items = new List<(string, string)>
        {
            ("client_id", clientId), ("redirect_uri", redirectUri), ("response_type", "code"), ("state", state),
        };
        if (kind.OAuthUsesPkce())
        {
            items.Add(("code_challenge", challenge));
            items.Add(("code_challenge_method", "S256"));
        }
        if (kind == ProviderKind.Azure) items.Add(("response_mode", "query"));
        if (kind.OAuthScopes().Length > 0) items.Add(("scope", kind.OAuthScopes()));
        return Uri.TryCreate($"{AuthorizeUrl}?{Encode(items)}", UriKind.Absolute, out var url) && IsWeb(url) ? url : null;
    }

    public Task<OAuthTokens> ExchangeAsync(string code, string verifier, string redirectUri, CancellationToken token = default)
    {
        var form = new List<(string, string)>
        {
            ("client_id", clientId), ("grant_type", "authorization_code"), ("code", code), ("redirect_uri", redirectUri),
        };
        if (kind.OAuthUsesPkce()) form.Add(("code_verifier", verifier));
        if (kind == ProviderKind.Azure) form.Add(("scope", kind.OAuthScopes()));
        return TokenRequestAsync(form, token);
    }

    public async Task<OAuthTokens> RefreshAsync(OAuthTokens tokens, CancellationToken token = default)
    {
        var refresh = tokens.RefreshToken ?? throw OAuthException.Expired;
        var form = new List<(string, string)>
        {
            ("client_id", clientId), ("grant_type", "refresh_token"), ("refresh_token", refresh),
        };
        if (kind == ProviderKind.Azure) form.Add(("scope", kind.OAuthScopes()));
        var fresh = await TokenRequestAsync(form, token);
        return fresh.RefreshToken is null ? fresh with { RefreshToken = refresh } : fresh;
    }

    // MARK: Device flow

    public async Task<DeviceCode> StartDeviceFlowAsync(CancellationToken token = default)
    {
        var json = await PostAsync(DeviceUrl, [("client_id", clientId), ("scope", kind.OAuthScopes())], token);
        // The address is opened in the browser, so it must be a web page.
        if (Text(json, "device_code") is not { } device || Text(json, "user_code") is not { } user
            || !Uri.TryCreate(Text(json, "verification_uri"), UriKind.Absolute, out var page) || !IsWeb(page))
            throw new OAuthException(Text(json, "error_description") ?? "Couldn’t start device sign-in.");
        return new DeviceCode(device, user, page, Number(json, "interval") ?? 5, Number(json, "expires_in") ?? 900);
    }

    /// <summary>Polls until the user approves in the browser. Honours `slow_down`; throws on denial or expiry.</summary>
    public async Task<OAuthTokens> PollDeviceFlowAsync(DeviceCode device, CancellationToken token = default)
    {
        var interval = Math.Clamp(device.Interval, 1, 60);
        var waited = 0;
        var limit = Math.Min(device.ExpiresIn, 3600);
        while (waited <= limit)
        {
            await _sleep(interval, token);
            waited += interval;
            var json = await PostAsync(TokenUrl,
            [
                ("client_id", clientId), ("device_code", device.Code),
                ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
            ], token);
            switch (Text(json, "error"))
            {
                case null: return Tokens(json);
                case "authorization_pending": continue;
                case "slow_down": interval += 5; break;
                case "access_denied": throw OAuthException.Denied;
                case "expired_token": throw OAuthException.Expired;
                default: throw new OAuthException(Text(json, "error_description") ?? "Sign-in failed.");
            }
        }
        throw OAuthException.Expired;
    }

    // MARK: Plumbing

    private async Task<OAuthTokens> TokenRequestAsync(List<(string, string)> form, CancellationToken token)
    {
        var json = await PostAsync(TokenUrl, form, token);
        if (Text(json, "error") is { } error) throw new OAuthException(Text(json, "error_description") ?? error);
        var tokens = Tokens(json);
        return kind.OAuthNeedsClientSecret() ? tokens with { ClientSecret = clientSecret } : tokens;
    }

    private static OAuthTokens Tokens(JsonElement json)
    {
        var access = Text(json, "access_token");
        if (string.IsNullOrEmpty(access)) throw OAuthException.InvalidResponse;
        var expires = Number(json, "expires_in");
        return new OAuthTokens(access, Text(json, "refresh_token"),
            expires is { } seconds ? DateTimeOffset.UtcNow.AddSeconds(seconds) : null);
    }

    private static string? Text(JsonElement json, string name) =>
        json.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static int? Number(JsonElement json, string name) =>
        !json.TryGetProperty(name, out var v) ? null
        : v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n
        : v.ValueKind == JsonValueKind.String && int.TryParse(v.GetString(), out var parsed) ? parsed : null;

    /// <summary>https, or http only when the account's own server is plain HTTP.</summary>
    private bool IsWeb(Uri url) => url.Scheme == Uri.UriSchemeHttps
        || (url.Scheme == Uri.UriSchemeHttp && origin.StartsWith("http://", StringComparison.Ordinal));

    private async Task<JsonElement> PostAsync(string url, List<(string, string)> form, CancellationToken token)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri)) throw OAuthException.InvalidResponse;
        using var request = new HttpRequestMessage(HttpMethod.Post, uri)
        {
            Content = new StringContent(Encode(form), Encoding.ASCII, "application/x-www-form-urlencoded"),
        };
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("GitWolf", "1.0"));
        if (kind.OAuthNeedsClientSecret() && !string.IsNullOrEmpty(clientSecret))
            request.Headers.Authorization = new AuthenticationHeaderValue(
                "Basic", Convert.ToBase64String(Encoding.UTF8.GetBytes($"{clientId}:{clientSecret}")));

        byte[] body;
        try
        {
            (body, _) = await _transport(request).WaitAsync(token);
        }
        catch (Exception e) when (e is HttpRequestException || (e is TaskCanceledException && !token.IsCancellationRequested))
        {
            System.Diagnostics.Trace.TraceWarning($"A sign-in request failed: {e.GetType().Name}");
            throw new OAuthException($"GitWolf couldn’t reach {uri.Host}. Check your connection and try again.");
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            return doc.RootElement.ValueKind == JsonValueKind.Object
                ? doc.RootElement.Clone()
                : throw OAuthException.InvalidResponse;
        }
        catch (JsonException)
        {
            throw OAuthException.InvalidResponse;
        }
    }

    private static string Encode(IEnumerable<(string Key, string Value)> form) =>
        string.Join('&', form.Select(f => $"{f.Key}={Uri.EscapeDataString(f.Value)}"));
}
