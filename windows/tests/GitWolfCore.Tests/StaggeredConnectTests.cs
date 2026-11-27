using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public sealed class StaggeredConnectTests
{
    private sealed class Connection(int target) : IDisposable
    {
        public int Target { get; } = target;
        public void Dispose() { }
    }

    private static readonly TimeSpan Head = TimeSpan.FromMilliseconds(20);

    [Fact]
    public async Task AnAddressThatDoesNotAnswerIsOvertakenAndStopped()
    {
        var stopped = new TaskCompletionSource();

        var won = await StaggeredConnect.FirstAsync<int, Connection>([1, 2], async (target, token) =>
        {
            if (target == 2) return new Connection(target);
            token.Register(() => stopped.SetResult());
            await Task.Delay(Timeout.Infinite, token);
            return new Connection(target);
        }, Head);

        Assert.Equal(2, won.Target);
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task ARefusedAddressMovesOnAtOnceAndAllRefusedIsAnError()
    {
        var won = await StaggeredConnect.FirstAsync<int, Connection>([1, 2], (target, _) => target == 1
            ? Task.FromException<Connection>(new IOException())
            : Task.FromResult(new Connection(target)), TimeSpan.FromMinutes(1))
            .WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(2, won.Target);

        await Assert.ThrowsAsync<HttpRequestException>(() => StaggeredConnect.FirstAsync<int, Connection>(
            [1, 2], (_, _) => Task.FromException<Connection>(new IOException()), Head));
    }

    [Fact]
    public async Task CancellingStopsWaiting()
    {
        using var cancel = new CancellationTokenSource(Head);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => StaggeredConnect.FirstAsync<int, Connection>(
            [1], async (target, token) =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return new Connection(target);
            }, Head, cancel.Token));
    }
}
