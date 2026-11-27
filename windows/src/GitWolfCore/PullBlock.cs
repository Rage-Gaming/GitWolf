namespace GitWolf.Core;

/// <summary>Why git refused to pull: local work that the incoming commits would overwrite.</summary>
/// <param name="Files">The files git named. Empty when it only said there are uncommitted changes.</param>
public sealed record PullBlock(IReadOnlyList<string> Files)
{
    private static readonly string[] ListHeaders =
    [
        "Your local changes to the following files would be overwritten by",
        "The following untracked working tree files would be overwritten by",
    ];

    private static readonly string[] Refusals =
    [
        "cannot pull with rebase: You have unstaged changes",
        "cannot pull with rebase: Your index contains uncommitted changes",
    ];

    /// <summary>Null when the failure has another cause. Git runs with an English locale.</summary>
    public static PullBlock? Parse(string stderr)
    {
        var files = new List<string>();
        var blocked = false;
        var listing = false;
        foreach (var line in stderr.Split('\n').Select(l => l.TrimEnd('\r')))
        {
            if (line.StartsWith("error: ", StringComparison.Ordinal)
                && ListHeaders.Any(h => line.Contains(h, StringComparison.Ordinal)))
            {
                blocked = listing = true;
            }
            else if (listing && line.StartsWith('\t'))
            {
                files.Add(line[1..]);
            }
            else
            {
                listing = false;
                blocked |= Refusals.Any(r => line.Contains(r, StringComparison.Ordinal));
            }
        }
        return blocked ? new PullBlock(files.Distinct().ToList()) : null;
    }
}
