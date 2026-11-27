using System.Collections.Concurrent;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace GitWolf.Core;

/// <summary>A setting in the repository's own configuration that runs a program or redirects a sign-in.</summary>
public sealed record RiskySetting(string Source, string Key, string Value);

/// <summary>What a repository's own configuration (and its submodules') asks git to do.</summary>
/// <param name="Fingerprint">Changes whenever the risky settings do, so trust has to be given again.</param>
/// <param name="BlocksCredential">An HTTP or proxy setting could send an account token somewhere else.</param>
public sealed record RepositoryRisk(IReadOnlyList<RiskySetting> Settings, string Fingerprint, bool BlocksCredential);

/// <summary>Git would run programs this repository configures, and the user hasn't agreed to that.</summary>
public sealed class UntrustedRepositoryException(RepositoryRisk risk) : GitException("trust", 128,
    "This repository’s own configuration runs programs or redirects sign-ins, so GitWolf hasn’t read it. "
    + "Trust it to continue.")
{
    public RepositoryRisk Risk { get; } = risk;
}

/// <summary>
/// The repositories the user has agreed to, kept in a file outside any repository. Windows-only: the
/// macOS app has no equivalent.
/// </summary>
public sealed class RepositoryTrust(string path)
{
    private readonly object _lock = new();
    private Dictionary<string, string>? _trusted;

    public bool IsTrusted(string root, string fingerprint)
    {
        lock (_lock) return Entries().GetValueOrDefault(Key(root)) == fingerprint;
    }

    public void Trust(string root, string fingerprint)
    {
        lock (_lock)
        {
            Entries()[Key(root)] = fingerprint;
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                var temporary = path + ".tmp";
                File.WriteAllText(temporary, JsonSerializer.Serialize(_trusted));
                File.Move(temporary, path, overwrite: true);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Still trusted until the app closes; it asks again next time.
                Trace.TraceWarning($"Trust could not be saved: {e.GetType().Name}");
            }
        }
    }

    private static string Key(string root)
    {
        var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        return OperatingSystem.IsWindows() ? full.ToLowerInvariant() : full;
    }

    private Dictionary<string, string> Entries()
    {
        if (_trusted is not null) return _trusted;
        try
        {
            if (File.Exists(path))
                _trusted = JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path));
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Trust could not be read: {e.GetType().Name}");
        }
        return _trusted ??= [];
    }
}

/// <summary>
/// Reads a repository's own configuration without letting it run anything: only `git config` and an
/// `ls-files` with the file-system monitor switched off.
/// </summary>
internal static class RepositoryInspector
{
    private const int MaxDepth = 8;

    private sealed record Scan(string Stamp, IReadOnlyList<string> Watched, RepositoryRisk Risk);

    private sealed class Slot
    {
        public readonly SemaphoreSlim Gate = new(1, 1);
        public Scan? Last;
    }

    private static readonly ConcurrentDictionary<(string Root, string? Git), Slot> Cache = new();

    /// <summary>Cached until a configuration file, HEAD or the index changes.</summary>
    internal static async Task<RepositoryRisk> InspectAsync(string root, string? gitPath, CancellationToken token = default)
    {
        var slot = Cache.GetOrAdd((root, gitPath), _ => new Slot());
        await slot.Gate.WaitAsync(token).ConfigureAwait(false);
        try
        {
            if (slot.Last is { } last && Stamp(last.Watched) == last.Stamp) return last.Risk;
            slot.Last = await ScanAsync(root, gitPath, token).ConfigureAwait(false);
            return slot.Last.Risk;
        }
        finally
        {
            slot.Gate.Release();
        }
    }

    private static string Stamp(IReadOnlyList<string> files)
    {
        var text = new StringBuilder();
        foreach (var file in files)
        {
            var info = new FileInfo(file);
            if (info.Exists) text.Append(info.LastWriteTimeUtc.Ticks).Append(':').Append(info.Length);
            text.Append(';');
        }
        return text.ToString();
    }

    private static async Task<Scan> ScanAsync(string root, string? gitPath, CancellationToken token)
    {
        var git = new GitRunner(root, gitPath);
        var gitDir = OperationDetector.GitDirectory(root);
        var common = CommonDirectory(gitDir);
        var watched = new HashSet<string>(StringComparer.Ordinal)
        {
            Path.Combine(common, "config"), Path.Combine(gitDir, "config.worktree"),
            Path.Combine(gitDir, "HEAD"), Path.Combine(gitDir, "index"),
        };
        // Stamped before reading, so a change made during the scan is noticed next time.
        var before = watched.ToDictionary(f => f, f => Stamp([f]));
        var found = new List<RiskySetting>();

        await ReadConfigAsync(git, root, [], "this repository", watched, found, token).ConfigureAwait(false);

        var modules = new List<string>();
        FindModules(Path.Combine(common, "modules"), 0, modules);
        if (gitDir != common) FindModules(Path.Combine(gitDir, "modules"), 0, modules);
        await FindEmbeddedAsync(root, gitPath, "", 0, watched, modules, token).ConfigureAwait(false);
        foreach (var module in modules.Distinct())
        {
            watched.Add(Path.Combine(module, "config"));
            watched.Add(Path.Combine(module, "config.worktree"));
            var name = Path.GetRelativePath(root, module).Replace('\\', '/');
            await ReadConfigAsync(git, root, [$"--git-dir={module}"], name, watched, found, token).ConfigureAwait(false);
        }

        var ordered = found.Distinct()
            .OrderBy(s => s.Source, StringComparer.Ordinal).ThenBy(s => s.Key, StringComparer.Ordinal)
            .ThenBy(s => s.Value, StringComparer.Ordinal).ToList();
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(
            string.Concat(ordered.Select(s => $"{s.Source}\0{s.Key}\0{s.Value}\0")))));
        var risk = new RepositoryRisk(ordered, hash, ordered.Any(s => RedirectsSignIn(s.Key)));
        var files = watched.ToList();
        var stamp = string.Concat(files.Select(f => before.GetValueOrDefault(f) ?? Stamp([f])));
        return new Scan(stamp, files, risk);
    }

    private static async Task ReadConfigAsync(
        GitRunner git, string root, string[] options, string source, HashSet<string> watched,
        List<RiskySetting> found, CancellationToken token)
    {
        var output = await git.RunAsync(
            [.. options, "config", "--list", "--show-scope", "--show-origin", "--includes", "-z"],
            readOnly: true, cancellationToken: token).ConfigureAwait(false);
        // Triples: scope, origin, "key\nvalue".
        var fields = ByteSplitting.SplitBytes(output, 0);
        for (var i = 0; i + 2 < fields.Count; i += 3)
        {
            if (fields[i] is not ("local" or "worktree")) continue;
            var entry = fields[i + 2];
            var newline = entry.IndexOf('\n');
            var key = newline < 0 ? entry : entry[..newline];
            // A key with no "=" means true.
            var value = newline < 0 ? "true" : entry[(newline + 1)..];
            if (fields[i + 1].StartsWith("file:", StringComparison.Ordinal))
            {
                var file = Path.GetFullPath(Path.Combine(root, fields[i + 1][5..]));
                watched.Add(file);
                // An included file that doesn't exist yet must be noticed when it appears.
                if (key.StartsWith("include", StringComparison.Ordinal) && key.EndsWith(".path", StringComparison.Ordinal))
                    watched.Add(IncludedFile(file, value));
            }
            if (IsRisky(key, value)) found.Add(new RiskySetting(source, key, value));
        }
    }

    private static string IncludedFile(string from, string value)
    {
        if (value.StartsWith("~/", StringComparison.Ordinal))
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), value[2..]);
        return Path.Combine(Path.GetDirectoryName(from)!, value);
    }

    /// <summary>The directory shared by all worktrees, which holds the main `config`.</summary>
    private static string CommonDirectory(string gitDir)
    {
        var pointer = Path.Combine(gitDir, "commondir");
        return File.Exists(pointer)
            ? Path.GetFullPath(Path.Combine(gitDir, File.ReadAllText(pointer).Trim()))
            : gitDir;
    }

    /// <summary>Submodule git directories kept under `modules/`, whose names may contain slashes.</summary>
    private static void FindModules(string directory, int depth, List<string> found)
    {
        if (depth > MaxDepth || !Directory.Exists(directory)) return;
        foreach (var child in Directory.EnumerateDirectories(directory))
        {
            if (File.Exists(Path.Combine(child, "HEAD")))
            {
                found.Add(child);
                FindModules(Path.Combine(child, "modules"), depth + 1, found);
            }
            else
            {
                FindModules(child, depth + 1, found);
            }
        }
    }

    /// <summary>Submodules that keep their git directory inside their own folder: `status` reads those too.</summary>
    private static async Task FindEmbeddedAsync(
        string root, string? gitPath, string prefix, int depth, HashSet<string> watched, List<string> found,
        CancellationToken token)
    {
        var folder = Path.Combine(root, prefix);
        if (depth > MaxDepth || !File.Exists(Path.Combine(OperationDetector.GitDirectory(folder), "index"))) return;
        var output = await new GitRunner(folder, gitPath).RunAsync(
            ["-c", "core.fsmonitor=false", "ls-files", "--stage", "-z"], readOnly: true, cancellationToken: token)
            .ConfigureAwait(false);
        foreach (var line in ByteSplitting.SplitBytes(output, 0))
        {
            // "160000 <hash> <stage>\t<path>" is a submodule.
            if (!line.StartsWith("160000 ", StringComparison.Ordinal)) continue;
            var path = Path.Combine(prefix, line[(line.IndexOf('\t') + 1)..]);
            var module = Path.Combine(root, path);
            var dotGit = Path.Combine(module, ".git");
            watched.Add(dotGit);
            watched.Add(Path.Combine(dotGit, "config"));
            if (!Directory.Exists(dotGit) && !File.Exists(dotGit)) continue;
            var gitDir = OperationDetector.GitDirectory(module);
            if (File.Exists(Path.Combine(gitDir, "HEAD"))) found.Add(Path.GetFullPath(gitDir));
            await FindEmbeddedAsync(root, gitPath, path, depth + 1, watched, found, token).ConfigureAwait(false);
        }
    }

    /// <summary>
    /// Settings that make git run a program, allow a transport that does, or change where HTTP requests
    /// go. Git lowercases section and variable names; the part between them keeps its case.
    /// </summary>
    internal static bool IsRisky(string key, string value)
    {
        if (RedirectsSignIn(key)) return true;
        if (value.Length == 0) return false;
        var first = key.IndexOf('.');
        if (first < 0) return false;
        var last = key.LastIndexOf('.');
        var section = key[..first];
        var name = key[(last + 1)..];
        var subsection = last > first ? key[(first + 1)..last] : null;
        var isBoolean = value.ToLowerInvariant() is "true" or "false" or "yes" or "no" or "on" or "off" or "0" or "1";
        return section switch
        {
            "core" => name is "sshcommand" or "gitproxy" or "askpass" or "editor" or "pager" or "alternaterefscommand"
                || (name == "fsmonitor" && !isBoolean),
            "sequence" => name == "editor",
            "interactive" => name == "difffilter",
            "pager" => !isBoolean,
            "filter" => name is "clean" or "smudge" or "process",
            "diff" => subsection is null ? name == "external" : name is "textconv" or "command",
            "merge" => subsection is not null && name == "driver",
            "mergetool" or "difftool" => name == "cmd",
            "gpg" => name is "program" or "defaultkeycommand",
            "credential" => name == "helper",
            "remote" => name is "uploadpack" or "receivepack" or "vcs"
                || (name is "url" or "pushurl" && value.Contains("::", StringComparison.Ordinal)),
            "url" => name is "insteadof" or "pushinsteadof" && subsection?.Contains("::", StringComparison.Ordinal) == true,
            "protocol" => name == "allow" && !value.Equals("never", StringComparison.OrdinalIgnoreCase),
            "submodule" => name == "update" && value.StartsWith('!'),
            "trailer" => name is "command" or "cmd",
            "gc" => name == "recentobjectshook",
            "lfs" => subsection is not null
                && ((subsection.StartsWith("customtransfer.", StringComparison.Ordinal) && name == "path")
                    || (subsection.StartsWith("extension.", StringComparison.Ordinal) && name is "clean" or "smudge")),
            _ => false,
        };
    }

    /// <summary>
    /// A proxy, or any `http.*` setting (TLS checks, certificates, headers, including URL-specific ones),
    /// apart from a few that only tune transfers.
    /// </summary>
    private static bool RedirectsSignIn(string key)
    {
        if (key.StartsWith("remote.", StringComparison.Ordinal) && key.EndsWith(".proxy", StringComparison.Ordinal))
            return true;
        return key.StartsWith("http.", StringComparison.Ordinal)
            && key[(key.LastIndexOf('.') + 1)..] is not ("postbuffer" or "lowspeedlimit" or "lowspeedtime" or "version");
    }
}
