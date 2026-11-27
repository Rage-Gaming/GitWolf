using System.Text.Json;

namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/CIStatus.swift.

/// <summary>Ordered from least to most important: the worst state wins.</summary>
public enum CheckState { Neutral, Success, Pending, Failure }

public sealed record CiCheck(string Name, CheckState State, Uri? Url);

/// <summary>All CI checks reported for one commit, plus the overall result.</summary>
public sealed record CiStatus(IReadOnlyList<CiCheck> Checks)
{
    public static CiStatus None { get; } = new([]);

    public bool IsEmpty => Checks.Count == 0;

    /// <summary>Any failure fails it, otherwise anything pending, otherwise success.</summary>
    public CheckState? Overall => IsEmpty ? null : Checks.Max(c => c.State);

    public string Summary
    {
        get
        {
            if (IsEmpty) return "No checks";
            var failed = Checks.Count(c => c.State == CheckState.Failure);
            if (failed > 0) return $"{failed} of {Checks.Count} checks failed";
            var pending = Checks.Count(c => c.State == CheckState.Pending);
            return pending > 0 ? $"{pending} of {Checks.Count} checks running" : $"All {Checks.Count} checks passed";
        }
    }
}

public static class CiProviderExtensions
{
    public static bool SupportsChecks(this ProviderKind kind) => kind != ProviderKind.Azure;
}

public sealed partial class ProviderClient
{
    /// <summary>CI checks for a commit: GitHub check runs and statuses, GitLab jobs, Gitea and Bitbucket statuses.</summary>
    public async Task<CiStatus> CiStatusAsync(string repoPath, string sha) =>
        new((await ReadChecksAsync(repoPath, sha)).Checks.Select(c => c with { Url = Openable(c.Url) }).ToList());

    private async Task<CiStatus> ReadChecksAsync(string repoPath, string sha)
    {
        if (sha.Length == 0 || !sha.All(char.IsAsciiHexDigit)) return CiStatus.None;
        List<CiCheck> checks;
        switch (Account.Kind)
        {
            case ProviderKind.GitHub:
                checks = ParseGitHubCheckRuns(await FetchAsync($"{Repo(repoPath)}/commits/{sha}/check-runs?per_page=100"));
                // Older integrations report through the commit status API instead.
                try
                {
                    checks.AddRange(ParseStatuses(
                        await FetchAsync($"{Repo(repoPath)}/commits/{sha}/status?per_page=100"), "state"));
                }
                catch (ProviderException e)
                {
                    System.Diagnostics.Trace.TraceWarning($"Commit statuses could not be read (HTTP {e.Status}).");
                }
                break;
            case ProviderKind.GitLab:
                checks = ParseStatusArray(
                    await FetchAsync($"{Repo(repoPath)}/repository/commits/{sha}/statuses?per_page=100"));
                break;
            case ProviderKind.Gitea:
                checks = ParseStatuses(await FetchAsync($"{Repo(repoPath)}/commits/{sha}/status"), "status");
                break;
            case ProviderKind.Bitbucket when Account.Host == "bitbucket.org":
            {
                using var doc = ParseJson(await FetchAsync($"{Repo(repoPath)}/commit/{sha}/statuses?pagelen=100"));
                if (Property(doc.RootElement, "values") is not { ValueKind: JsonValueKind.Array } values)
                    throw ProviderException.InvalidResponse;
                checks = values.EnumerateArray()
                    .Select(r => Check(GetString(r, "name") ?? GetString(r, "key"), GetString(r, "state"), GetString(r, "url")))
                    .OfType<CiCheck>().ToList();
                break;
            }
            default:
                throw ProviderException.Unsupported($"CI status isn’t available for {Account.Kind.Title()}.");
        }
        // The same job can be reported more than once (re-runs); keep the latest of each name.
        return new CiStatus(checks.DistinctBy(c => c.Name)
            .OrderByDescending(c => c.State).ThenBy(c => c.Name, StringComparer.Ordinal).ToList());
    }

    /// <summary>Maps each provider's wording onto four states.</summary>
    internal static CheckState CheckStateFor(string? raw) => (raw ?? "").ToLowerInvariant() switch
    {
        "success" or "successful" or "passed" or "completed" => CheckState.Success,
        "failure" or "failed" or "error" or "timed_out" or "action_required" or "startup_failure" or "stopped" => CheckState.Failure,
        "pending" or "running" or "in_progress" or "inprogress" or "queued" or "created" or "waiting_for_resource"
            or "preparing" or "scheduled" or "manual" or "warning" => CheckState.Pending,
        _ => CheckState.Neutral,
    };

    private static CiCheck? Check(string? name, string? state, string? url) =>
        name is null ? null : new CiCheck(name, CheckStateFor(state), Link(url));

    internal static List<CiCheck> ParseGitHubCheckRuns(byte[] data)
    {
        using var doc = ParseJson(data);
        if (Property(doc.RootElement, "check_runs") is not { ValueKind: JsonValueKind.Array } runs)
            throw ProviderException.InvalidResponse;
        var result = new List<CiCheck>();
        foreach (var r in runs.EnumerateArray())
        {
            if (GetString(r, "name") is not { } name) continue;
            var state = GetString(r, "status") != "completed" ? CheckState.Pending : GetString(r, "conclusion") switch
            {
                "success" => CheckState.Success,
                "cancelled" or "failure" or "timed_out" or "action_required" or "startup_failure" or "stale" => CheckState.Failure,
                _ => CheckState.Neutral,
            };
            result.Add(new CiCheck(name, state, Link(GetString(r, "html_url"))));
        }
        return result;
    }

    /// <summary>The `{ "statuses": [...] }` shape of GitHub and Gitea.</summary>
    internal static List<CiCheck> ParseStatuses(byte[] data, string stateKey)
    {
        using var doc = ParseJson(data);
        if (Property(doc.RootElement, "statuses") is not { ValueKind: JsonValueKind.Array } items)
            throw ProviderException.InvalidResponse;
        return items.EnumerateArray()
            .Select(r => Check(GetString(r, "context"), GetString(r, stateKey), GetString(r, "target_url")))
            .OfType<CiCheck>().ToList();
    }

    /// <summary>GitLab's plain list of jobs.</summary>
    internal static List<CiCheck> ParseStatusArray(byte[] data) => ArrayOf(data)
        .Select(r => Check(GetString(r, "name"), GetString(r, "status"), GetString(r, "target_url")))
        .OfType<CiCheck>().ToList();
}
