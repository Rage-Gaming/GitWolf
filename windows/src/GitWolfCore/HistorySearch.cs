using System.Globalization;

namespace GitWolf.Core;

public enum HistorySearchKind
{
    /// <summary>Commit message text.</summary>
    Message,
    /// <summary>Author name or email.</summary>
    Author,
    /// <summary>Commits that add or remove this exact text.</summary>
    ContentChanged,
    /// <summary>Commits whose diff has a line matching this regular expression.</summary>
    ContentRegex,
}

/// <summary>A history query that git evaluates. Ported from HistorySearch.swift.</summary>
public sealed record HistoryQuery(
    HistorySearchKind Kind = HistorySearchKind.Message, string Text = "", string Path = "",
    DateOnly? Since = null, DateOnly? Until = null)
{
    public bool IsEmpty =>
        string.IsNullOrWhiteSpace(Text) && string.IsNullOrWhiteSpace(Path) && Since is null && Until is null;

    /// <summary>Arguments for `git log`, built so typed text can never be read as an option.</summary>
    internal IEnumerable<string> Arguments()
    {
        var term = Text.Trim();
        if (term.Length > 0)
        {
            string[] filter = Kind switch
            {
                HistorySearchKind.Message => ["--regexp-ignore-case", "--fixed-strings", $"--grep={term}"],
                HistorySearchKind.Author => ["--regexp-ignore-case", $"--author={term}"],
                HistorySearchKind.ContentChanged => [$"-S{term}"],
                _ => [$"-G{term}"],
            };
            foreach (var argument in filter) yield return argument;
        }
        static string Day(DateOnly date) => date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        if (Since is { } since) yield return $"--since={Day(since)} 00:00:00";
        if (Until is { } until) yield return $"--until={Day(until)} 23:59:59";
    }
}

public sealed partial class GitRepository
{
    /// <summary>Commits across all refs matching the query, newest first.</summary>
    public async Task<List<Commit>> SearchAsync(
        HistoryQuery query, ISet<string> remotes, int limit = 500, CancellationToken cancellationToken = default)
    {
        // Content searches would otherwise run the repository's text conversion commands.
        List<string> args =
        [
            "--literal-pathspecs", "log", "--no-show-signature", "--all", "--topo-order", "-z", "-n", $"{limit}",
            "--no-textconv", "--no-ext-diff", $"--format={LogParser.Format}", .. query.Arguments(),
        ];
        var path = query.Path.Trim();
        if (path.Length > 0) args.AddRange(["--", path]);
        var data = await Git.RunAsync(args, readOnly: true, cancellationToken: cancellationToken);
        return LogParser.Parse(data, remotes);
    }
}
