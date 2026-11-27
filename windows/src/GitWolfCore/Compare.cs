namespace GitWolf.Core;

/// <summary>The difference between two refs. Ported from Compare.swift.</summary>
/// <param name="Base">Commit actually diffed from: the merge base when comparing since the common ancestor.</param>
/// <param name="Commits">Commits in the compared ref that the other lacks, newest first (at most 500).</param>
/// <param name="Ahead">How many commits only the compared ref has.</param>
/// <param name="Behind">How many commits it is missing.</param>
public sealed record RefComparison(
    string Base, string Head, IReadOnlyList<FileChange> Files, IReadOnlyList<Commit> Commits, int Ahead, int Behind);

public sealed partial class GitRepository
{
    private async Task<string> ResolveCommitAsync(string reference)
    {
        var name = reference.Trim();
        if (name.Length == 0 || name.StartsWith('-'))
            throw new GitException("rev-parse", 1, "Enter a branch, tag or commit.");
        try
        {
            return (await Git.RunStringAsync(["rev-parse", "--verify", "--quiet", $"{name}^{{commit}}"], readOnly: true))
                .Trim();
        }
        catch (GitException)
        {
            throw new GitException("rev-parse", 1, $"“{name}” isn’t a branch, tag or commit in this repository.");
        }
    }

    private async Task<int> CountCommitsAsync(string range) =>
        int.Parse((await Git.RunStringAsync(["rev-list", "--count", range, "--"], readOnly: true)).Trim(),
            System.Globalization.CultureInfo.InvariantCulture);

    /// <summary>
    /// Compares <paramref name="to"/> against <paramref name="from"/>. With
    /// <paramref name="sinceAncestor"/> the files are those changed on <paramref name="to"/> since
    /// the two diverged; otherwise every difference between the two tips.
    /// </summary>
    public async Task<RefComparison> CompareAsync(
        string from, string to, bool sinceAncestor, ISet<string> remotes)
    {
        var fromHash = await ResolveCommitAsync(from);
        var toHash = await ResolveCommitAsync(to);
        var @base = fromHash;
        if (sinceAncestor)
        {
            // Exit code 1: unrelated histories, which have no common ancestor to start from.
            var output = await Git.RunAsync(["merge-base", fromHash, toHash], readOnly: true,
                allowedExitCodes: new HashSet<int> { 0, 1 });
            var ancestor = System.Text.Encoding.UTF8.GetString(output).Trim();
            if (ancestor.Length > 0) @base = ancestor;
        }
        var files = RefParser.ParseNameStatus(
            await Git.RunAsync(["diff", "--name-status", "-z", "-M", @base, toHash, "--"], readOnly: true));
        var commits = LogParser.Parse(
            await Git.RunAsync(
                ["log", "--topo-order", "-z", "-n", "500", $"--format={LogParser.Format}", $"{fromHash}..{toHash}", "--"],
                readOnly: true), remotes);
        return new RefComparison(@base, toHash, files, commits,
            await CountCommitsAsync($"{fromHash}..{toHash}"), await CountCommitsAsync($"{toHash}..{fromHash}"));
    }
}
