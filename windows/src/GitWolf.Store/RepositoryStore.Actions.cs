using GitWolf.Core;

namespace GitWolf.Store;

/// <summary>User-defined actions. Ported from StoreTools.swift.</summary>
public sealed partial class RepositoryStore
{
    private const int ShownOutput = 600;

    /// <summary>
    /// Runs the action at the repository's root. It doesn't make the repository busy: an action may keep
    /// running for as long as a program it opens.
    /// </summary>
    public async Task RunActionAsync(CustomAction action, string gitPath)
    {
        var (root, branch) = (Repo.Root, Status.Branch);
        var result = await Task.Run(() => CustomActionRunner.RunAsync(action, root, branch, gitPath));
        if (result.Succeeded) return;
        var output = result.Output.Trim();
        if (output.Length > ShownOutput) output = output[^ShownOutput..];
        ErrorMessage = $"“{action.Name}” failed (exit code {result.ExitCode})."
            + (output.Length == 0 ? "" : $"\n\n{output}");
    }
}
