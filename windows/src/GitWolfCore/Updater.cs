namespace GitWolf.Core;

/// <summary>An update step that failed, with a message that can be shown.</summary>
public sealed class UpdateException : Exception
{
    public UpdateException(string message, Exception? inner = null) : base(message, inner) { }
}

/// <summary>A downloaded archive whose signature matched. Only <see cref="Updater"/> makes these.</summary>
public sealed class VerifiedUpdate
{
    internal VerifiedUpdate(AppVersion version, byte[] archive) => (Version, Archive) = (version, archive);

    public AppVersion Version { get; }
    internal byte[] Archive { get; }
}

/// <summary>
/// Finds, downloads and verifies a newer release. The feed must be signed with the release key, and
/// nothing is unpacked unless the archive carries a signature from it too.
/// </summary>
public sealed class Updater
{
    public static readonly Uri Feed = new("https://ipuppyyt.github.io/GitWolf/appcast-windows.xml");
    public const string ReleasesPage = "https://github.com/ipuppyyt/GitWolf/releases/latest";
    /// <summary>The public half of the key releases are signed with; the same one macOS ships.</summary>
    public const string ReleaseKey = "762/jLI7hK4y8xJgidyDo4SK96Gt8lFRbZcAp/sycXI=";
    public const long MaxArchiveBytes = 500L * 1024 * 1024;

    private static readonly TimeSpan Stall = TimeSpan.FromSeconds(30);

    private readonly HttpClient _http;
    private readonly AppVersion _current;
    private readonly string _publicKey;
    private readonly Version _system;

    public Updater(HttpClient http, AppVersion current, string publicKey = ReleaseKey, Version? system = null) =>
        (_http, _current, _publicKey, _system) = (http, current, publicKey, system ?? Environment.OSVersion.Version);

    /// <summary>A client that sends no cookies or credentials. .NET never redirects from https to http.</summary>
    public static HttpClient CreateClient()
    {
        var client = new HttpClient(new SocketsHttpHandler
        {
            ConnectCallback = StaggeredConnect.ConnectAsync, UseCookies = false,
        })
        {
            // Each read has its own limit; a large download may take long overall.
            Timeout = Timeout.InfiniteTimeSpan,
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("GitWolf");
        return client;
    }

    /// <summary>The newest release that is newer than this one and can be installed here, or null.</summary>
    public async Task<AppcastItem?> CheckAsync(CancellationToken token = default)
    {
        var feed = await ReadAsync(Feed, Appcast.MaxBytes, exact: false, null, token).ConfigureAwait(false);
        if (!Appcast.IsSigned(feed, _publicKey))
            throw new UpdateException("The update feed’s signature doesn’t match, so it was ignored.");
        IReadOnlyList<AppcastItem> items;
        try
        {
            items = Appcast.Parse(new MemoryStream(feed));
        }
        catch (FormatException e)
        {
            throw new UpdateException("The update feed couldn’t be read.", e);
        }
        AppcastItem? best = null;
        var newest = _current;
        foreach (var item in items)
        {
            if (!AppVersion.TryParse(item.Version, out var version) || version.Prerelease is not null) continue;
            if (!(version > newest) || !Installable(item)) continue;
            (best, newest) = (item, version);
        }
        return best;
    }

    /// <summary>Downloads a release and checks its signature before returning any of it.</summary>
    public async Task<VerifiedUpdate> DownloadAsync(AppcastItem item, IProgress<double>? progress = null,
        CancellationToken token = default)
    {
        if (!AppVersion.TryParse(item.Version, out var version) || !(version > _current) || !Installable(item))
            throw new UpdateException("This release can’t be installed.");
        var archive = await ReadAsync(new Uri(item.Url), (int)item.Length, exact: true, progress, token)
            .ConfigureAwait(false);
        var valid = await Task.Run(() => UpdateSigning.Verify(archive, item.Signature, _publicKey), token)
            .ConfigureAwait(false);
        return valid
            ? new VerifiedUpdate(version, archive)
            : throw new UpdateException("The download’s signature doesn’t match, so it was not installed.");
    }

    private bool Installable(AppcastItem item) =>
        Uri.TryCreate(item.Url, UriKind.Absolute, out var url) && url.Scheme == Uri.UriSchemeHttps
        && url.Host == "github.com" && url.IsDefaultPort && url.UserInfo.Length == 0
        && item.Length is > 0 and <= MaxArchiveBytes && item.Signature.Length > 0
        && (item.MinimumSystemVersion.Length == 0
            || (System.Version.TryParse(item.MinimumSystemVersion, out var minimum) && _system >= minimum));

    /// <summary>
    /// A response body of at most <paramref name="size"/> bytes, or exactly that many. A transfer that
    /// stops sending is given up on.
    /// </summary>
    private async Task<byte[]> ReadAsync(Uri url, int size, bool exact, IProgress<double>? progress,
        CancellationToken token)
    {
        using var stall = CancellationTokenSource.CreateLinkedTokenSource(token);
        try
        {
            stall.CancelAfter(Stall);
            using var response = await _http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, stall.Token)
                .ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                throw new UpdateException($"The update server answered {(int)response.StatusCode}.");
            await using var body = await response.Content.ReadAsStreamAsync(stall.Token).ConfigureAwait(false);
            // One spare byte shows a body that is longer than allowed.
            var buffer = new byte[size + 1];
            var total = 0;
            var reported = -1;
            while (total < buffer.Length)
            {
                stall.CancelAfter(Stall);
                var read = await body.ReadAsync(buffer.AsMemory(total), stall.Token).ConfigureAwait(false);
                if (read == 0) break;
                total += read;
                // Whole percents only, so the window isn't redrawn for every packet.
                var percent = (int)(Math.Min(total, size) * 100L / size);
                if (percent == reported) continue;
                reported = percent;
                progress?.Report(percent / 100.0);
            }
            if (total > size || (exact && total != size))
                throw new UpdateException("The download isn’t the expected size.");
            if (total != buffer.Length) Array.Resize(ref buffer, total);
            return buffer;
        }
        catch (OperationCanceledException e) when (!token.IsCancellationRequested)
        {
            throw new UpdateException("The update server stopped responding.", e);
        }
        catch (Exception e) when (e is HttpRequestException or IOException)
        {
            throw new UpdateException("Couldn’t reach the update server. Check your connection.", e);
        }
    }
}
