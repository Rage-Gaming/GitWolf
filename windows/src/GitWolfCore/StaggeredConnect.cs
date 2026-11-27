using System.Net;
using System.Net.Sockets;

namespace GitWolf.Core;

/// <summary>
/// Connects to a host that has several addresses without waiting on one that doesn't answer. .NET tries
/// them one after another, so a single unreachable address can use up a request's whole time limit.
/// </summary>
public static class StaggeredConnect
{
    private static readonly TimeSpan Head = TimeSpan.FromMilliseconds(250);

    public static async ValueTask<Stream> ConnectAsync(SocketsHttpConnectionContext context, CancellationToken token)
    {
        var addresses = await Dns.GetHostAddressesAsync(context.DnsEndPoint.Host, token).ConfigureAwait(false);
        var port = context.DnsEndPoint.Port;
        var socket = await FirstAsync(addresses, (address, cancel) => OpenAsync(address, port, cancel), Head, token)
            .ConfigureAwait(false);
        return new NetworkStream(socket, ownsSocket: true);
    }

    /// <summary>
    /// Starts an attempt per target, the next one when the previous fails or has had a head start. Returns
    /// the first to succeed, stops the others and disposes any that also succeeded.
    /// </summary>
    public static async Task<TResult> FirstAsync<TTarget, TResult>(IReadOnlyList<TTarget> targets,
        Func<TTarget, CancellationToken, Task<TResult>> attempt, TimeSpan head, CancellationToken token = default)
        where TResult : IDisposable
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(token);
        var running = new List<Task<TResult>>();
        Exception? failure = null;
        var next = 0;
        try
        {
            while (next < targets.Count || running.Count > 0)
            {
                if (next < targets.Count) running.Add(attempt(targets[next++], stop.Token));
                var waiting = running.Cast<Task>().ToList();
                if (next < targets.Count) waiting.Add(Task.Delay(head, stop.Token));
                await Task.WhenAny(waiting).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                foreach (var done in running.Where(t => t.IsCompleted).ToList())
                {
                    running.Remove(done);
                    if (done.IsCompletedSuccessfully) return done.Result;
                    failure = done.Exception?.InnerException ?? failure;
                }
            }
            throw new HttpRequestException("No address of the host could be reached.", failure);
        }
        finally
        {
            stop.Cancel();
            foreach (var other in running)
                _ = other.ContinueWith(t =>
                {
                    if (t.IsCompletedSuccessfully) t.Result.Dispose();
                    else _ = t.Exception;
                }, TaskScheduler.Default);
        }
    }

    private static async Task<Socket> OpenAsync(IPAddress address, int port, CancellationToken token)
    {
        var socket = new Socket(address.AddressFamily, SocketType.Stream, ProtocolType.Tcp) { NoDelay = true };
        try
        {
            await socket.ConnectAsync(address, port, token).ConfigureAwait(false);
            return socket;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }
}
