namespace GitWolf.Core;

/// <summary>A commit that a Git hook refused, with everything the hook printed.</summary>
public sealed class HookFailedException(string hook, string output)
    : Exception($"The {hook} hook failed.\n\n{output}")
{
    public string Hook { get; } = hook;
    public string Output { get; } = output;
}

/// <summary>The repository's signing settings.</summary>
public sealed record SigningConfig(bool SignsByDefault, bool HasKey)
{
    /// <summary>Whether signing has a chance of working without further setup.</summary>
    public bool IsConfigured => SignsByDefault || HasKey;
}

// Committing. Ported from Signing.swift and Hooks.swift.
public sealed partial class GitRepository
{
    /// <param name="sign">Null follows `commit.gpgsign`.</param>
    /// <exception cref="HookFailedException">A commit hook refused the commit.</exception>
    public async Task CommitAsync(string message, bool amend, bool? sign = null, bool skipHooks = false)
    {
        var args = new List<string> { "commit" };
        if (amend) args.Add("--amend");
        if (sign is { } choice) args.Add(choice ? "--gpg-sign" : "--no-gpg-sign");
        if (skipHooks) args.Add("--no-verify");
        if (message.Trim().Length == 0) args.Add("--no-edit");
        else args.AddRange(["-m", message]);
        try
        {
            await Git.RunAsync(args);
        }
        catch (GitException error) when (!skipHooks)
        {
            if (HookDiagnosis.Diagnose(error.Stderr, await ActiveHooksAsync()) is { } hook) throw hook;
            throw;
        }
    }

    /// <summary>
    /// Names of the hooks present in the hooks directory (honours `core.hooksPath`). Git for Windows
    /// has no executable bit, so any file that isn't a sample counts.
    /// </summary>
    public async Task<IReadOnlyList<string>> ActiveHooksAsync()
    {
        try
        {
            var path = (await Git.RunStringAsync(["rev-parse", "--git-path", "hooks"], readOnly: true)).Trim();
            if (path.Length == 0 || IsNetworkPath(path)) return [];
            return Directory.EnumerateFiles(Path.Combine(Root, path))
                .Select(f => Path.GetFileName(f))
                .Where(f => !f.EndsWith(".sample", StringComparison.OrdinalIgnoreCase))
                .ToList();
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    public async Task<SigningConfig> SigningConfigAsync()
    {
        string output;
        try
        {
            output = await Git.RunStringAsync(
                ["config", "--get-regexp", @"^(commit\.gpgsign|user\.signingkey)$"], readOnly: true);
        }
        catch (GitException)
        {
            return new SigningConfig(false, false); // Git fails when neither is set.
        }
        // Later lines win, as in git. A key with no value means true.
        var values = new Dictionary<string, string>();
        foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var parts = line.Split(' ', 2);
            values[parts[0]] = parts.Length > 1 ? parts[1] : "true";
        }
        var signs = values.GetValueOrDefault("commit.gpgsign")?.ToLowerInvariant() is "true" or "yes" or "on" or "1";
        return new SigningConfig(signs, !string.IsNullOrEmpty(values.GetValueOrDefault("user.signingkey")));
    }

    /// <summary>Opening a network path on Windows sends the user's credentials to that server.</summary>
    private static bool IsNetworkPath(string path) =>
        path.Replace('/', '\\').StartsWith(@"\\", StringComparison.Ordinal);
}

public static partial class HookDiagnosis
{
    /// <summary>Commit hooks that can stop a commit, in the order git runs them.</summary>
    private static readonly string[] BlockingHooks = ["pre-commit", "prepare-commit-msg", "commit-msg"];

    /// <summary>Messages git prints when a commit fails for reasons unrelated to hooks.</summary>
    private static readonly string[] NativeFailures =
    [
        "nothing to commit", "no changes added to commit", "nothing added to commit", "Author identity unknown",
        "empty ident name", "Aborting commit due to empty commit message", "gpg failed to sign",
        "failed to write commit object", "cannot do a partial commit during a merge", "unable to create",
        "unmerged files", "You are in the middle of",
    ];

    private const int MaxOutput = 20_000;

    /// <summary>Decides whether a failed commit was a hook's doing.</summary>
    public static HookFailedException? Diagnose(string stderr, IReadOnlyList<string> activeHooks)
    {
        var output = TerminalCodes().Replace(stderr, "").Trim();
        if (output.Length == 0
            || NativeFailures.Any(f => output.Contains(f, StringComparison.OrdinalIgnoreCase))) return null;
        // The end of long output is where the failure is.
        if (output.Length > MaxOutput) output = "…" + output[^MaxOutput..];
        var hook = BlockingHooks.FirstOrDefault(activeHooks.Contains);
        return hook is null ? null : new HookFailedException(hook, output);
    }

    [System.Text.RegularExpressions.GeneratedRegex("\u001b\\[[0-9;?]*[A-Za-z]")]
    private static partial System.Text.RegularExpressions.Regex TerminalCodes();
}
