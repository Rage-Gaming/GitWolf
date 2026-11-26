namespace GitSync.Core;

// Changes made on a remote. Deleting is destructive, so the UI confirms it first.
public sealed partial class GitRepository
{
    public Task PushTagAsync(string name, string remote) => PushRefAsync(remote, $"refs/tags/{name}");

    public async Task PushAllTagsAsync(string remote)
    {
        var net = await NetworkGitAsync();
        await net.RunAsync(["push", Operand(remote), "--tags"]);
    }

    /// <summary>Removes the tag from the remote. The local tag is kept.</summary>
    public Task DeleteRemoteTagAsync(string name, string remote) =>
        PushRefAsync(remote, $"refs/tags/{name}", "--delete");

    public Task DeleteRemoteBranchAsync(string remote, string branch) =>
        PushRefAsync(remote, $"refs/heads/{branch}", "--delete");

    /// <summary>Full ref names, so a branch and a tag with the same name can't be confused.</summary>
    private async Task PushRefAsync(string remote, string reference, params string[] options)
    {
        var net = await NetworkGitAsync();
        await net.RunAsync(["push", .. options, Operand(remote), reference]);
    }

    /// <summary>
    /// Splits "origin/feature/x" into remote and branch. Remote names may contain slashes, so the
    /// longest configured remote wins. Null when no remote matches.
    /// </summary>
    public static (string Remote, string Branch)? SplitRemoteBranch(string name, IEnumerable<string> remotes)
    {
        var remote = remotes
            .Where(r => name.Length > r.Length + 1 && name.StartsWith(r + "/", StringComparison.Ordinal))
            .MaxBy(r => r.Length);
        return remote is null ? null : (remote, name[(remote.Length + 1)..]);
    }
}
