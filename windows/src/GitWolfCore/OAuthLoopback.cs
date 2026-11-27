using System.Net;
using System.Net.Sockets;
using System.Text;

namespace GitWolf.Core;

// Ported from LoopbackServer in apple/Sources/GitWolfApp/OAuthSignIn.swift.

/// <summary>
/// A one-shot HTTP listener on 127.0.0.1 that catches the browser's redirect and returns the
/// authorization code. The redirect URI is fixed, and must be registered exactly on the application.
/// </summary>
public sealed class OAuthLoopback : IDisposable
{
    public const int DefaultPort = 53682;
    public static readonly string RedirectUri = $"http://127.0.0.1:{DefaultPort}/callback";

    private const int MaxRequestBytes = 8192;
    private readonly TcpListener _listener;

    /// <summary>Listens straight away, so the browser can't come back before anyone is there.</summary>
    public OAuthLoopback(int port = DefaultPort)
    {
        // Loopback only, and exclusive: no other program can share the port and read the code.
        _listener = new TcpListener(IPAddress.Loopback, port);
        try
        {
            if (OperatingSystem.IsWindows()) _listener.ExclusiveAddressUse = true;
            _listener.Start();
        }
        catch (SocketException)
        {
            throw new OAuthException(
                $"Port {port} is busy, so sign-in can’t listen for the browser. Close the other sign-in window and try again.");
        }
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
    }

    public int Port { get; }

    public void Dispose() => _listener.Stop();

    public async Task<string> WaitForCodeAsync(string state, CancellationToken cancellationToken = default, TimeSpan? timeout = null)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        limit.CancelAfter(timeout ?? TimeSpan.FromMinutes(5));
        var result = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            while (true)
            {
                var accept = _listener.AcceptTcpClientAsync(limit.Token).AsTask();
                if (await Task.WhenAny(accept, result.Task) == result.Task) break;
                // Handled side by side: a connection that sends nothing can't hold up the real one.
                _ = HandleAsync(await accept, state, result, limit.Token);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            if (!result.Task.IsCompleted) throw OAuthException.Expired;
        }
        return await result.Task;
    }

    private static async Task HandleAsync(
        TcpClient client, string state, TaskCompletionSource<string> result, CancellationToken cancellationToken)
    {
        using var _ = client;
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            limit.CancelAfter(TimeSpan.FromSeconds(10));
            var stream = client.GetStream();
            var buffer = new byte[MaxRequestBytes];
            var length = 0;
            // Read the headers to the end, so closing the socket doesn't reset the browser's connection.
            while (length < buffer.Length && !Encoding.ASCII.GetString(buffer, 0, length).Contains("\r\n\r\n"))
            {
                var read = await stream.ReadAsync(buffer.AsMemory(length), limit.Token);
                if (read == 0) break;
                length += read;
            }
            var parts = Encoding.ASCII.GetString(buffer, 0, length).Split('\n')[0].Split(' ');
            var target = parts.Length > 1 && parts[0] == "GET" ? parts[1] : "";
            var question = target.IndexOf('?');
            if ((question < 0 ? target : target[..question]) != "/callback")
            {
                await RespondAsync(stream, "404 Not Found", "Not found", limit.Token);
                return;
            }
            var query = new Dictionary<string, string>();
            foreach (var pair in (question < 0 ? "" : target[(question + 1)..]).Split('&', StringSplitOptions.RemoveEmptyEntries))
            {
                var equals = pair.IndexOf('=');
                var name = equals < 0 ? pair : pair[..equals];
                query.TryAdd(Decode(name), equals < 0 ? "" : Decode(pair[(equals + 1)..]));
            }

            // An answer without our state isn't from the sign-in we started: refuse it and keep waiting.
            if (query.GetValueOrDefault("state") != state)
            {
                await RespondAsync(stream, "400 Bad Request", "This doesn’t match the sign-in GitWolf started.", limit.Token);
                return;
            }
            var code = query.GetValueOrDefault("code", "");
            var failure = code.Length > 0 ? null
                : query.GetValueOrDefault("error") == "access_denied" ? OAuthException.Denied
                : new OAuthException(query.GetValueOrDefault("error_description", "Sign-in failed."));
            try
            {
                // Nothing from the request is echoed into the page.
                await RespondAsync(stream, "200 OK", failure is null
                    ? "Signed in. You can close this tab and return to GitWolf."
                    : "Sign-in failed. You can close this tab and try again in GitWolf.", limit.Token);
            }
            finally
            {
                if (failure is null) result.TrySetResult(code);
                else result.TrySetException(failure);
            }
        }
        catch (Exception e) when (e is IOException or SocketException or OperationCanceledException)
        {
            // A dropped or silent connection: keep waiting for the real one.
            System.Diagnostics.Trace.TraceWarning($"Sign-in connection failed: {e.GetType().Name}");
        }
    }

    private static string Decode(string value) => Uri.UnescapeDataString(value.Replace('+', ' '));

    private static async Task RespondAsync(NetworkStream stream, string status, string text, CancellationToken token)
    {
        var html = "<!doctype html><meta charset=utf-8><title>GitWolf</title>"
            + $"<body style=\"font:16px 'Segoe UI',sans-serif;padding:48px;text-align:center\">{text}</body>";
        var response = $"HTTP/1.1 {status}\r\nContent-Type: text/html; charset=utf-8\r\n"
            + $"Content-Length: {Encoding.UTF8.GetByteCount(html)}\r\nConnection: close\r\n\r\n{html}";
        await stream.WriteAsync(Encoding.UTF8.GetBytes(response), token);
        await stream.FlushAsync(token);
    }
}
