using System.Net;

namespace GitWolf.Core;

/// <summary>An answer to a picture request. <paramref name="RetryAt"/> is set when GitHub asks to wait.</summary>
public sealed record AvatarResponse(
    byte[] Body, HttpStatusCode Status, string? ETag = null, DateTimeOffset? RetryAt = null,
    DateTimeOffset? LastModified = null);

public delegate Task<AvatarResponse> AvatarTransport(HttpRequestMessage request);

public static class AvatarHttp
{
    // No redirects, so only the hosts that were checked are ever contacted. The buffer limit stops an
    // oversized reply before it is held in memory.
    private static readonly HttpClient Client = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false, ConnectCallback = StaggeredConnect.ConnectAsync,
    })
    {
        Timeout = TimeSpan.FromSeconds(20), MaxResponseContentBufferSize = 5 * 1024 * 1024,
    };

    public static readonly AvatarTransport Transport = async request =>
    {
        using var response = await Client.SendAsync(request).ConfigureAwait(false);
        var body = await response.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
        return new AvatarResponse(body, response.StatusCode, response.Headers.ETag?.ToString(), RetryAt(response),
            response.Content.Headers.LastModified);
    };

    private static DateTimeOffset? RetryAt(HttpResponseMessage response)
    {
        if (response.Headers.RetryAfter is { } after)
            return after.Date ?? DateTimeOffset.UtcNow + after.Delta;
        // The last allowed request says so too, before any is refused.
        if (Header(response, "x-ratelimit-remaining") != "0") return null;
        return long.TryParse(Header(response, "x-ratelimit-reset"), out var seconds)
            && seconds is > 0 and < 100_000_000_000
                ? DateTimeOffset.FromUnixTimeSeconds(seconds) : null;
    }

    private static string? Header(HttpResponseMessage response, string name) =>
        response.Headers.TryGetValues(name, out var values) ? values.FirstOrDefault() : null;
}
