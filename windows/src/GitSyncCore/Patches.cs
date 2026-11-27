namespace GitSync.Core;

// Patch files. Ported from Patches.swift.
public sealed partial class GitRepository
{
    /// <summary>
    /// Writes one mbox-format patch (with author and message) per commit into
    /// <paramref name="directory"/>, numbered in the order given, and returns the files.
    /// </summary>
    public async Task<IReadOnlyList<string>> FormatPatchesAsync(IReadOnlyList<string> revisions, string directory)
    {
        Directory.CreateDirectory(directory);
        var written = new List<string>();
        for (var i = 0; i < revisions.Count; i++)
        {
            var output = await Git.RunStringAsync(
                ["format-patch", "-1", $"--start-number={i + 1}", "--src-prefix=a/", "--dst-prefix=b/",
                    "-o", directory, Operand(revisions[i])]);
            written.AddRange(output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(Path.GetFullPath));
        }
        return written;
    }

    /// <summary>
    /// A plain patch of uncommitted work: staged changes only, or everything tracked. Bytes, so
    /// line endings survive. Prefixes are fixed and external diff tools are never run.
    /// </summary>
    public Task<byte[]> WorkingPatchAsync(bool stagedOnly) => Git.RunAsync(
        ["diff", "--binary", "--no-color", "--no-ext-diff", "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/",
            stagedOnly ? "--cached" : "HEAD", "--"], readOnly: true);

    /// <summary>Null when `git apply` would accept the patch; otherwise git's complaint.</summary>
    public async Task<string?> CheckPatchAsync(string file)
    {
        try
        {
            await Git.RunAsync(["apply", "--check", "--", file], readOnly: true);
            return null;
        }
        catch (GitException e)
        {
            return e.Message;
        }
    }

    /// <summary>Applies a patch to the working tree, and to the index when asked, without committing.</summary>
    public Task ApplyPatchFileAsync(string file, bool stage) =>
        Git.RunAsync(stage ? ["apply", "--index", "--", file] : ["apply", "--", file]);

    /// <summary>
    /// Applies mailbox patches as commits, keeping author and message. Stops on conflict, leaving an
    /// operation to continue, skip or abort.
    /// </summary>
    public Task ApplyMailboxAsync(IReadOnlyList<string> files) => Git.RunAsync(["am", "--3way", "--", .. files]);
}
