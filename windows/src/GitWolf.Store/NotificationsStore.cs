using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

/// <summary>
/// Review requests, mentions and assignments across every connected account, refreshed every few
/// minutes. UI thread only. Ported from NotificationsStore.swift.
/// </summary>
public sealed class NotificationsStore(AccountStore accounts, HttpTransport? transport = null) : IDisposable
{
    public sealed record Entry(ProviderAccount Account, ProviderNotification Note);

    public sealed record Problem(ProviderAccount Account, string Message);

    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);
    private readonly CancellationTokenSource _lifetime = new();
    private bool _polling;
    private bool _again;

    public event Action? Changed;

    public IReadOnlyList<Entry> Entries { get; private set; } = [];
    public IReadOnlyList<Problem> Problems { get; private set; } = [];
    public bool IsLoading { get; private set; }
    public bool IsLoaded { get; private set; }
    public int UnreadCount => Entries.Count(e => e.Note.Unread);
    /// <summary>Whether any saved account can have notifications.</summary>
    public bool HasAccounts => accounts.Accounts.Any(a => a.Kind.SupportsNotifications());

    public async void StartPolling()
    {
        if (_polling) return;
        _polling = true;
        using var timer = new PeriodicTimer(Interval);
        try
        {
            do
            {
                await RefreshAsync();
            } while (await timer.WaitForNextTickAsync(_lifetime.Token));
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            // Normal shutdown.
        }
        catch (Exception e)
        {
            // async void: nothing may escape and end the process.
            Trace.TraceError($"Notification polling stopped: {e.GetType().Name}");
            _polling = false;
        }
    }

    public async Task RefreshAsync()
    {
        if (IsLoading)
        {
            _again = true;
            return;
        }
        IsLoading = true;
        Changed?.Invoke();
        try
        {
            do
            {
                _again = false;
                var results = await Task.WhenAll(accounts.Accounts
                    .Where(a => a.Kind.SupportsNotifications()).Select(a => Task.Run(() => LoadAsync(a))));
                // An account removed while loading must not reappear.
                var ids = accounts.Accounts.Select(a => a.Id).ToHashSet();
                Entries = results.SelectMany(r => r.Entries).Where(e => ids.Contains(e.Account.Id))
                    .OrderByDescending(e => e.Note.Updated ?? DateTimeOffset.MinValue).ToList();
                Problems = results.Select(r => r.Problem).OfType<Problem>().Where(p => ids.Contains(p.Account.Id)).ToList();
                IsLoaded = true;
            } while (_again && !_lifetime.IsCancellationRequested);
        }
        finally
        {
            IsLoading = false;
            Changed?.Invoke();
        }
    }

    private async Task<(IEnumerable<Entry> Entries, Problem? Problem)> LoadAsync(ProviderAccount account)
    {
        try
        {
            if (await ClientAsync(account) is not { } client) return ([], null);
            return ((await client.NotificationsAsync()).Select(n => new Entry(account, n)), null);
        }
        catch (ProviderException e)
        {
            var message = !e.IsUnauthorized ? e.Message
                : account.Kind == ProviderKind.GitHub
                    ? "This token can’t read notifications. Create one with the “notifications” scope."
                    : "This account’s credentials were rejected.";
            return ([], new Problem(account, message));
        }
    }

    private async Task<ProviderClient?> ClientAsync(ProviderAccount account) =>
        await accounts.SecretAsync(account) is { Length: > 0 } secret ? new ProviderClient(account, secret, transport) : null;

    public async Task MarkReadAsync(Entry entry)
    {
        Entries = Entries.Where(e => e != entry).ToList();
        Changed?.Invoke();
        await SendAsync(entry.Account, c => c.MarkReadAsync(entry.Note));
    }

    public async Task MarkAllReadAsync()
    {
        var affected = Entries.Select(e => e.Account).DistinctBy(a => a.Id).ToList();
        Entries = [];
        Changed?.Invoke();
        foreach (var account in affected) await SendAsync(account, c => c.MarkAllReadAsync());
    }

    private async Task SendAsync(ProviderAccount account, Func<ProviderClient, Task> send)
    {
        try
        {
            if (await ClientAsync(account) is { } client) await Task.Run(() => send(client));
        }
        catch (ProviderException e)
        {
            Problems = [.. Problems.Where(p => p.Account.Id != account.Id), new Problem(account, e.Message)];
            Changed?.Invoke();
        }
    }

    public void Dispose() => _lifetime.Cancel();
}
