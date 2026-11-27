using System.Text;

namespace GitSync.Core;

public enum SubmoduleState { UpToDate, NotInitialized, Modified, Conflicted }

/// <summary>A repository nested inside this one. Ported from Submodules.swift.</summary>
public sealed record Submodule(string Path, string Hash, SubmoduleState State, string Url)
{
    /// <summary>`git submodule status`: flag, hash, path, then a description; flag is space, `-`, `+` or `U`.</summary>
    internal static List<Submodule> Parse(string status, IReadOnlyDictionary<string, string> urls)
    {
        var result = new List<Submodule>();
        foreach (var raw in status.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var rest = raw[1..].TrimEnd('\r').Split(' ', 2);
            if (rest.Length != 2) continue;
            var path = rest[1];
            var paren = path.LastIndexOf(" (", StringComparison.Ordinal);
            if (paren >= 0 && path.EndsWith(')')) path = path[..paren];
            var state = raw[0] switch
            {
                '-' => SubmoduleState.NotInitialized,
                '+' => SubmoduleState.Modified,
                'U' => SubmoduleState.Conflicted,
                _ => SubmoduleState.UpToDate,
            };
            result.Add(new(path, rest[0], state, urls.GetValueOrDefault(path, "")));
        }
        return result;
    }

    /// <summary>Path to URL, from `config --get-regexp` output over .gitmodules.</summary>
    internal static Dictionary<string, string> Urls(string config)
    {
        var paths = new Dictionary<string, string>(StringComparer.Ordinal);
        var urls = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in config.Split('\n', StringSplitOptions.RemoveEmptyEntries))
        {
            var parts = line.TrimEnd('\r').Split(' ', 2);
            if (parts.Length != 2 || !parts[0].StartsWith("submodule.", StringComparison.Ordinal)) continue;
            var key = parts[0][10..];
            if (key.EndsWith(".path", StringComparison.Ordinal)) paths[key[..^5]] = parts[1];
            else if (key.EndsWith(".url", StringComparison.Ordinal)) urls[key[..^4]] = parts[1];
        }
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, path) in paths)
            if (urls.TryGetValue(name, out var url)) result[path] = url;
        return result;
    }
}

public sealed partial class GitRepository
{
    public async Task<IReadOnlyList<Submodule>> SubmodulesAsync()
    {
        if (!File.Exists(Path.Combine(Root, ".gitmodules"))) return [];
        var status = Git.RunStringAsync(["submodule", "status"], readOnly: true);
        // Exit code 1 means nothing matched.
        var config = Git.RunAsync(
            ["config", "-f", ".gitmodules", "--get-regexp", @"^submodule\..*\.(path|url)$"],
            readOnly: true, allowedExitCodes: new HashSet<int> { 0, 1 });
        await Task.WhenAll(status, config);
        return Submodule.Parse(await status, Submodule.Urls(Encoding.UTF8.GetString(await config)));
    }

    /// <summary>Clones and checks out the commits this repository records: all, or just one path.</summary>
    public async Task UpdateSubmodulesAsync(string? path = null)
    {
        // Hooks are disabled so none can read the credential in the environment.
        var net = await NetworkGitAsync(disableHooks: true);
        string[] only = path is null ? [] : ["--", path];
        await net.RunAsync(["submodule", "update", "--init", "--recursive", .. only]);
    }

    /// <summary>Moves every submodule to the newest commit of its tracked branch.</summary>
    public async Task UpdateSubmodulesToLatestAsync()
    {
        var net = await NetworkGitAsync(disableHooks: true);
        await net.RunAsync(["submodule", "update", "--init", "--recursive", "--remote"]);
    }

    public async Task AddSubmoduleAsync(string url, string path)
    {
        Operand(url);
        Operand(path);
        var net = await NetworkGitAsync(disableHooks: true);
        await net.RunAsync(["submodule", "add", "--", url, path]);
    }
}
