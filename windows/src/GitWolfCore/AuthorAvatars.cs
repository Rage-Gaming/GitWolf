using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace GitWolf.Core;

public sealed record AuthorPage(
    IReadOnlyDictionary<string, Uri> Found, bool HasMore = false, bool Failed = false,
    DateTimeOffset? RetryAt = null);

/// <summary>
/// Finds profile pictures for commit authors on github.com. An account's token, when given, is sent to
/// api.github.com only, so private repositories work too. Only addresses on GitHub's picture host are
/// ever returned, and no email address is sent anywhere.
/// </summary>
public static partial class AuthorAvatars
{
    private const string PictureHost = "avatars.githubusercontent.com";
    private const int PageSize = 100;

    [GeneratedRegex(@"^(?:(?<id>\d{1,19})\+)?(?<login>[A-Za-z0-9](?:[A-Za-z0-9-]{0,38}))@users\.noreply\.github\.com$",
        RegexOptions.IgnoreCase)]
    private static partial Regex NoReply();

    [GeneratedRegex(@"^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$")]
    private static partial Regex OwnerAndName();

    /// <summary>GitHub's private addresses name the account, so no request is needed to find it.</summary>
    public static Uri? FromEmail(string email)
    {
        var match = NoReply().Match(email.Trim());
        if (!match.Success) return null;
        var path = match.Groups["id"].Success ? $"u/{match.Groups["id"].Value}" : match.Groups["login"].Value;
        return new Uri($"https://{PictureHost}/{path}?s=96");
    }

    /// <summary>Whether the repository's authors can be looked up.</summary>
    public static bool CanLookUp(RemoteLocation location) =>
        location.Host == "github.com" && OwnerAndName().IsMatch(location.Path)
        && !location.Path.EndsWith("/..", StringComparison.Ordinal) && !location.Path.EndsWith("/.", StringComparison.Ordinal);

    /// <summary>
    /// One page of a repository's latest commits, as pictures by author email. Empty and marked failed
    /// when the repository can't be read (private, without a token), the request limit is reached or
    /// there is no connection.
    /// </summary>
    public static async Task<AuthorPage> FetchPageAsync(
        RemoteLocation location, int page = 1, AvatarTransport? transport = null, string? token = null)
    {
        var found = new Dictionary<string, Uri>(StringComparer.OrdinalIgnoreCase);
        if (!CanLookUp(location)) return new(found, Failed: true);
        using var request = new HttpRequestMessage(HttpMethod.Get,
            $"https://api.github.com/repos/{location.Path}/commits?per_page={PageSize}&page={page}");
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("GitWolf", "1.0"));
        if (!string.IsNullOrEmpty(token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        try
        {
            var reply = await (transport ?? AvatarHttp.Transport)(request).ConfigureAwait(false);
            if (reply.Status != HttpStatusCode.OK) return new(found, Failed: true, RetryAt: reply.RetryAt);
            using var json = JsonDocument.Parse(reply.Body);
            if (json.RootElement.ValueKind != JsonValueKind.Array) return new(found, Failed: true);
            foreach (var item in json.RootElement.EnumerateArray())
            {
                // The author and committer of a commit can be different people.
                foreach (var role in new[] { "author", "committer" })
                {
                    if (Text(item, "commit", role, "email") is { } email
                        && Picture(Text(item, role, "avatar_url")) is { } picture)
                        found.TryAdd(email, picture);
                }
            }
            return new(found, HasMore: json.RootElement.GetArrayLength() == PageSize, RetryAt: reply.RetryAt);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            // Pictures are decoration: initials are shown instead.
            System.Diagnostics.Trace.TraceWarning($"Looking up profile pictures failed: {e.GetType().Name}");
            return new(found, Failed: true);
        }
    }

    private static string? Text(JsonElement element, params string[] path)
    {
        foreach (var name in path)
            if (element.ValueKind != JsonValueKind.Object || !element.TryGetProperty(name, out element))
                return null;
        return element.ValueKind == JsonValueKind.String ? element.GetString() : null;
    }

    /// <summary>The server's address, accepted only for the picture host over HTTPS, at a small size.</summary>
    internal static Uri? Picture(string? address)
    {
        if (!Uri.TryCreate(address, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps
            || uri.Host != PictureHost || !uri.IsDefaultPort || uri.UserInfo.Length > 0) return null;
        return new Uri($"https://{PictureHost}{uri.AbsolutePath}?s=96");
    }
}
