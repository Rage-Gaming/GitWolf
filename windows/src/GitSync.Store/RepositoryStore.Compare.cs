using System.Diagnostics;
using GitSync.Core;

namespace GitSync.Store;

// Comparing two refs, and rebasing.
public sealed partial class RepositoryStore
{
    private int _compareToken;

    public string CompareFrom { get; set; } = "";
    public string CompareTo { get; set; } = "";
    public bool CompareSinceAncestor { get; set; } = true;
    public RefComparison? Comparison { get; private set; }
    public bool IsComparing { get; private set; }
    public string? CompareError { get; private set; }

    /// <summary>Shows the compare panel, running straight away when both refs are given.</summary>
    public Task OpenCompareAsync(string? from = null, string? to = null)
    {
        var given = from is not null && to is not null;
        CompareFrom = from ?? (CompareFrom.Length > 0 ? CompareFrom : Status.Branch ?? "HEAD");
        CompareTo = to ?? CompareTo;
        if (given) SetComparison(null, null, comparing: false);
        Mode = StoreMode.Compare;
        return given || (CompareTo.Length > 0 && Comparison is null) ? RunCompareAsync() : Task.CompletedTask;
    }

    public Task SwapCompareAsync()
    {
        (CompareFrom, CompareTo) = (CompareTo, CompareFrom);
        if (Comparison is not null) return RunCompareAsync();
        Notify(nameof(Comparison));
        return Task.CompletedTask;
    }

    public async Task RunCompareAsync()
    {
        if (CompareFrom.Trim().Length == 0 || CompareTo.Trim().Length == 0) return;
        var token = ++_compareToken;
        var (repo, from, to, since) = (Repo, CompareFrom, CompareTo, CompareSinceAncestor);
        var remotes = new HashSet<string>(Remotes);
        // The old result's files must not stay selected under the new one.
        if (Mode == StoreMode.Compare) SelectTarget(null);
        SetComparison(null, null, comparing: true);
        RefComparison? result = null;
        string? error = null;
        try
        {
            result = await Task.Run(() => repo.CompareAsync(from, to, since, remotes));
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Comparing failed: {e.GetType().Name}");
            error = e.Message;
        }
        // A newer comparison replaces this one.
        if (token == _compareToken) SetComparison(result, error, comparing: false);
    }

    private void SetComparison(RefComparison? result, string? error, bool comparing)
    {
        if (!comparing) _compareToken++;
        Comparison = result;
        CompareError = error;
        IsComparing = comparing;
        Notify(nameof(Comparison));
    }

    public Task<bool> StartRebaseAsync(RebasePlan plan) =>
        PerformAsync("Rebasing…", r => r.StartInteractiveRebaseAsync(plan));

    /// <summary>Rewrites history: the UI confirms first.</summary>
    public Task<bool> RebaseOntoAsync(string target) => PerformAsync("Rebasing…", r => r.RebaseOntoAsync(target));
}
