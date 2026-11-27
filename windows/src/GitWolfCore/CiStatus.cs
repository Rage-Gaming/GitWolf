using System.Text.Json;
using System.Text.RegularExpressions;

namespace GitWolf.Core;

// Ported from apple/Sources/GitWolfCore/CIStatus.swift.

/// <summary>Ordered from least to most important: the worst state wins.</summary>
public enum CheckState { Neutral, Success, Pending, Failure }

public sealed record CiCheck(string Name, CheckState State, Uri? Url)
{
    /// <summary>The GitHub Actions run this check belongs to; cancelling acts on the whole run.</summary>
    public string? RunId { get; init; }

    /// <summary>The single job (GitHub Actions or GitLab) behind this check; re-running acts on it.</summary>
    public string? JobId { get; init; }
}

public enum CiAction { Rerun, Cancel }

/// <summary>All CI checks reported for one commit, plus the overall result.</summary>
public sealed record CiStatus(IReadOnlyList<CiCheck> Checks)
{
    public static CiStatus None { get; } = new([]);

    public bool IsEmpty => Checks.Count == 0;

    /// <summary>By content, so a repeated lookup with the same answer changes nothing.</summary>
    public bool Equals(CiStatus? other) => other is not null && Checks.SequenceEqual(other.Checks);

    public override int GetHashCode() => HashCode.Combine(Checks.Count, Checks.FirstOrDefault());

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

    /// <summary>Whether the provider's API can do this to the check. GitHub Actions and GitLab jobs only.</summary>
    public static bool CanPerform(this ProviderKind kind, CiAction action, CiCheck check)
    {
        var running = check.State == CheckState.Pending;
        if (running != (action == CiAction.Cancel)) return false;
        return kind switch
        {
            ProviderKind.GitHub => IsId(running ? check.RunId : check.JobId),
            ProviderKind.GitLab => IsId(check.JobId),
            _ => false,
        };
    }

    // Ids become part of a request path.
    private static bool IsId(string? id) => id is { Length: > 0 } && id.All(char.IsAsciiDigit);
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

    /// <summary>Re-runs a finished job or cancels a running one.</summary>
    public async Task PerformAsync(CiAction action, CiCheck check, string repoPath)
    {
        if (!Account.Kind.CanPerform(action, check))
            throw ProviderException.Unsupported(
                $"This check can’t be {(action == CiAction.Rerun ? "re-run" : "cancelled")} from here.");
        var repo = Repo(repoPath);
        var url = (Account.Kind, action) switch
        {
            (ProviderKind.GitHub, CiAction.Rerun) => $"{repo}/actions/jobs/{check.JobId}/rerun",
            (ProviderKind.GitHub, _) => $"{repo}/actions/runs/{check.RunId}/cancel",
            (_, CiAction.Rerun) => $"{repo}/jobs/{check.JobId}/retry",
            _ => $"{repo}/jobs/{check.JobId}/cancel",
        };
        await SendAsync(HttpMethod.Post, url);
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
            var link = GetString(r, "html_url");
            // Only an Actions job has an address of this shape; other apps' checks can't be controlled.
            var job = ActionsJob().Match(link ?? "");
            result.Add(new CiCheck(name, state, Link(link))
            {
                RunId = job.Success ? job.Groups[1].Value : null,
                JobId = job.Success ? job.Groups[2].Value : null,
            });
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
        // Each GitLab status is a job; its id is what retry and cancel need.
        .Select(r => Check(GetString(r, "name"), GetString(r, "status"), GetString(r, "target_url")) is { } check
            ? check with
            {
                JobId = Property(r, "id") is { ValueKind: JsonValueKind.Number } id ? id.GetRawText() : null,
            }
            : null)
        .OfType<CiCheck>().ToList();

    [GeneratedRegex(@"/actions/runs/([0-9]+)/job/([0-9]+)")]
    private static partial Regex ActionsJob();
}
