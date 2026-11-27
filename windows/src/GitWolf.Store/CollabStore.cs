using System.ComponentModel;
using System.Diagnostics;
using GitWolf.Core;

namespace GitWolf.Store;

/// <summary>Which account to use for a repository's host. <see cref="SignedIn"/> is false without a saved one.</summary>
public sealed record ProviderConnection(ProviderClient Client, string Path, bool SignedIn);

/// <summary>
/// Pull requests or issues for one repository, loaded page by page from the hosting provider. UI thread
/// only. Ported from Collab.swift.
/// </summary>
public sealed class CollabStore(CollabKind kind, Func<Task<ProviderConnection?>> connect) : INotifyPropertyChanged
{
    private static readonly TimeSpan FreshFor = TimeSpan.FromSeconds(60);
    private int _page = 1;
    private int _generation;
    private int? _commentsFor;
    private DateTimeOffset? _loadedAt;

    /// <summary>Raised after any visible state changed.</summary>
    public event PropertyChangedEventHandler? PropertyChanged;

    public CollabKind Kind { get; } = kind;
    public IReadOnlyList<CollabItem> Items { get; private set; } = [];
    public bool IsLoading { get; private set; }
    public bool HasMore { get; private set; }
    public string? Error { get; private set; }
    public IReadOnlyList<CollabComment> Comments { get; private set; } = [];
    public bool IsLoadingComments { get; private set; }
    public string? CommentsError { get; private set; }
    public bool IsWorking { get; private set; }
    public string? ActionError { get; private set; }
    public IReadOnlyList<string> RepositoryLabels { get; private set; } = [];
    /// <summary>Whether the selected items can be changed: a saved account on a provider we can write to.</summary>
    public bool CanWrite { get; private set; }

    private CollabFilter _filter = CollabFilter.Open;
    public CollabFilter Filter
    {
        get => _filter;
        set
        {
            if (_filter == value) return;
            _filter = value;
            _ = LoadAsync();
        }
    }

    private string _query = "";
    public string Query
    {
        get => _query;
        set
        {
            if (_query == value) return;
            _query = value;
            Notify();
        }
    }

    public int? SelectedNumber { get; private set; }
    public CollabItem? Selected => Items.FirstOrDefault(i => i.Number == SelectedNumber);

    public IReadOnlyList<CollabItem> VisibleItems
    {
        get
        {
            var q = Query.Trim();
            if (q.Length == 0) return Items;
            bool Has(string text) => text.Contains(q, StringComparison.OrdinalIgnoreCase);
            return Items.Where(i => Has(i.Title) || Has(i.Author) || q == $"#{i.Number}" || q == $"{i.Number}"
                || i.Labels.Any(Has)).ToList();
        }
    }

    public void Select(int? number)
    {
        if (SelectedNumber == number) return;
        SelectedNumber = number;
        ActionError = null;
        Notify();
        _ = LoadCommentsAsync();
    }

    /// <summary>Loads on first use and refreshes when the data is more than a minute old.</summary>
    public Task LoadIfNeededAsync() =>
        IsLoading || (_loadedAt is { } at && DateTimeOffset.UtcNow - at < FreshFor) ? Task.CompletedTask : LoadAsync();

    public Task LoadAsync() => FetchAsync(1, replacing: true);

    public Task LoadMoreAsync() => HasMore && !IsLoading ? FetchAsync(_page + 1, replacing: false) : Task.CompletedTask;

    /// <summary>Forgets everything, for example when the account or the remote changed.</summary>
    public void Reset()
    {
        _generation++;
        _loadedAt = null;
        _commentsFor = null;
        (Items, Comments, RepositoryLabels) = ([], [], []);
        (IsLoading, IsLoadingComments, HasMore, CanWrite) = (false, false, false, false);
        (Error, ActionError, CommentsError, SelectedNumber) = (null, null, null, null);
        Notify();
    }

    private async Task FetchAsync(int requested, bool replacing)
    {
        // Only the newest request may publish its result.
        var generation = ++_generation;
        IsLoading = true;
        Error = null;
        Notify();
        ProviderConnection? connection = null;
        try
        {
            connection = await connect();
            if (generation != _generation) return;
            if (connection is null)
            {
                Error = "This repository’s remote isn’t on a supported hosting provider.";
                Items = [];
                HasMore = false;
                return;
            }
            var (client, path, filter) = (connection.Client, connection.Path, Filter);
            var result = await Task.Run(() => client.CollabAsync(Kind, path, filter, requested));
            if (generation != _generation) return;
            _page = requested;
            HasMore = result.Count >= ProviderClient.CollabPageSize;
            Items = replacing ? result : [.. Items, .. result.Where(n => Items.All(i => i.Number != n.Number))];
            _loadedAt = DateTimeOffset.UtcNow;
            CanWrite = connection.SignedIn && client.Account.Kind.SupportsWriting(Kind, client.Account.Host);
            if (SelectedNumber is not null && Selected is null) SelectedNumber = null;
        }
        catch (ProviderException e)
        {
            if (generation != _generation) return;
            Error = Describe(e, connection?.SignedIn == true, connection?.Client.Account.Kind.Title() ?? "provider");
            if (replacing) (Items, HasMore) = ([], false);
        }
        finally
        {
            if (generation == _generation)
            {
                IsLoading = false;
                Notify();
            }
        }
    }

    private async Task LoadCommentsAsync()
    {
        if (SelectedNumber is not { } number)
        {
            (Comments, _commentsFor, CommentsError) = ([], null, null);
            Notify();
            return;
        }
        if (_commentsFor == number) return;
        _commentsFor = number;
        (Comments, IsLoadingComments, CommentsError) = ([], true, null);
        Notify();
        try
        {
            if (await connect() is not { } connection) return;
            var (client, path) = (connection.Client, connection.Path);
            if (!client.Account.Kind.SupportsWriting(Kind, client.Account.Host)) return;
            var result = await Task.Run(() => client.CommentsAsync(Kind, path, number));
            if (_commentsFor != number) return;
            Comments = result;
            if (RepositoryLabels.Count == 0 && connection.SignedIn)
                RepositoryLabels = await Task.Run(() => client.RepositoryLabelsAsync(path));
        }
        catch (ProviderException e)
        {
            Trace.TraceWarning($"Loading a conversation failed (HTTP {e.Status}).");
            if (_commentsFor == number) CommentsError = e.Message;
        }
        finally
        {
            if (_commentsFor == number)
            {
                IsLoadingComments = false;
                Notify();
            }
        }
    }

    /// <summary>Runs a change against the provider, then reloads the list and the conversation.</summary>
    private async Task<bool> ActAsync(Func<ProviderClient, string, int, Task> work)
    {
        if (IsWorking || SelectedNumber is not { } number) return false;
        IsWorking = true;
        ActionError = null;
        Notify();
        try
        {
            if (await connect() is not { SignedIn: true } connection)
            {
                ActionError = "Add an account for this host in Settings → Accounts.";
                return false;
            }
            await Task.Run(() => work(connection.Client, connection.Path, number));
            _commentsFor = null;
            await Task.WhenAll(LoadAsync(), LoadCommentsAsync());
            return true;
        }
        catch (ProviderException e)
        {
            ActionError = e.Message;
            return false;
        }
        finally
        {
            IsWorking = false;
            Notify();
        }
    }

    public Task<bool> AddCommentAsync(string text) => ActAsync((c, p, n) => c.AddCommentAsync(Kind, p, n, text));

    /// <summary>Changes the server: the UI must confirm first.</summary>
    public Task<bool> MergeAsync(MergeMethod method) => ActAsync((c, p, n) => c.MergeAsync(p, n, method));

    /// <summary>Changes the server: the UI must confirm closing first.</summary>
    public Task<bool> SetOpenAsync(bool open) => ActAsync((c, p, n) => c.SetOpenAsync(open, Kind, p, n));

    public Task<bool> SetLabelsAsync(IReadOnlyList<string> labels) =>
        ActAsync((c, p, n) => c.SetLabelsAsync(labels, Kind, p, n));

    /// <summary>Creates a pull request or issue and selects it. Throws the provider's explanation on failure.</summary>
    public async Task CreateAsync(
        string title, string body, string head = "", string baseBranch = "", bool draft = false)
    {
        if (await connect() is not { SignedIn: true } connection)
            throw ProviderException.Unsupported("Add an account for this repository’s host in Settings → Accounts.");
        var (client, path) = (connection.Client, connection.Path);
        var item = await Task.Run(() => Kind == CollabKind.PullRequest
            ? client.CreatePullRequestAsync(path, title, body, head, baseBranch, draft)
            : client.CreateIssueAsync(path, title, body));
        _filter = CollabFilter.Open;
        await LoadAsync();
        // The list can lag behind the create call.
        if (Items.All(i => i.Number != item.Number)) Items = [item, .. Items];
        Select(item.Number);
        Notify();
    }

    internal static string Describe(ProviderException error, bool signedIn, string provider) => error.Status switch
    {
        401 or 403 => signedIn
            ? $"{provider} rejected the saved credentials. Re-add the account in Settings → Accounts."
            : $"This repository is private or rate-limited. Add a {provider} account in Settings → Accounts.",
        404 => signedIn
            ? "Not found. The repository may be private to another account, or this feature is turned off."
            : $"Not found. If the repository is private, add a {provider} account in Settings → Accounts.",
        _ => error.Message,
    };

    private void Notify() => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
}
