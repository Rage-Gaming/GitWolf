using System.Diagnostics;
using System.Text;

namespace GitWolf.Core;

/// <summary>A failed git invocation.</summary>
public class GitException(string command, int exitCode, string stderr) : Exception(BuildMessage(command, exitCode, stderr))
{
    public string Command { get; } = command;
    public int ExitCode { get; } = exitCode;
    public string Stderr { get; } = stderr;

    private static string BuildMessage(string command, int exitCode, string stderr)
    {
        var message = stderr.Trim();
        return message.Length == 0 ? $"git {command} failed (exit code {exitCode})" : message;
    }
}

/// <summary>
/// Runs the system `git` binary. Every call is an independent process, so it is safe to
/// call concurrently from any context. Ported from GitRunner.swift.
/// </summary>
public sealed class GitRunner(string workingDirectory, string? gitPath = null, IReadOnlyDictionary<string, string>? extraEnvironment = null)
{
    public string WorkingDirectory { get; } = workingDirectory;
    public string GitPath { get; } = gitPath ?? ResolveDefaultGitPath();

    /// <summary>Extra environment for every process (e.g. credentials for network commands).</summary>
    public IReadOnlyDictionary<string, string> ExtraEnvironment { get; } = extraEnvironment ?? new Dictionary<string, string>();

    /// <summary>Awaited before every command; throws to refuse it.</summary>
    internal Func<CancellationToken, Task>? Preflight { get; init; }

    /// <summary>
    /// Resolves `git.exe` from PATH, falling back to the Git for Windows default install
    /// location, mirroring the macOS default of `/usr/bin/git` (PORTING.md).
    /// </summary>
    private static string ResolveDefaultGitPath()
    {
        var pathEnv = Environment.GetEnvironmentVariable("PATH") ?? "";
        var exeName = OperatingSystem.IsWindows() ? "git.exe" : "git";
        foreach (var dir in pathEnv.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            var candidate = Path.Combine(dir.Trim('"'), exeName);
            // Relative PATH entries could pick up a git.exe planted in the current folder.
            if (Path.IsPathFullyQualified(candidate) && File.Exists(candidate)) return candidate;
        }
        if (OperatingSystem.IsWindows())
        {
            foreach (var root in new[]
                     {
                         Environment.GetEnvironmentVariable("ProgramFiles"),
                         Environment.GetEnvironmentVariable("ProgramFiles(x86)"),
                     })
            {
                if (root is null) continue;
                var candidate = Path.Combine(root, "Git", "cmd", "git.exe");
                if (File.Exists(candidate)) return candidate;
            }
        }
        return exeName;
    }

    /// <param name="readOnly">
    /// Sets `GIT_OPTIONAL_LOCKS=0` so background refreshes never touch the index and therefore
    /// never trigger file-watcher feedback loops or lock errors.
    /// </param>
    /// <param name="allowedExitCodes">Exit codes treated as success (e.g. `git diff --no-index` returns 1).</param>
    public async Task<byte[]> RunAsync(
        IReadOnlyList<string> arguments,
        bool readOnly = false,
        IReadOnlySet<int>? allowedExitCodes = null,
        byte[]? input = null,
        Action<string>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        var allowed = allowedExitCodes ?? new HashSet<int> { 0 };
        if (Preflight is not null) await Preflight(cancellationToken);

        using var process = new Process();
        process.StartInfo.FileName = GitPath;
        foreach (var arg in arguments) process.StartInfo.ArgumentList.Add(arg);
        process.StartInfo.WorkingDirectory = WorkingDirectory;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;
        process.StartInfo.RedirectStandardInput = input is not null;
        process.StartInfo.StandardOutputEncoding = Encoding.UTF8;
        process.StartInfo.StandardErrorEncoding = Encoding.UTF8;
        process.StartInfo.CreateNoWindow = true;

        process.StartInfo.EnvironmentVariables.Clear();
        foreach (var (key, value) in BuildEnvironment(readOnly))
            process.StartInfo.EnvironmentVariables[key] = value;
        foreach (var (key, value) in ExtraEnvironment)
            process.StartInfo.EnvironmentVariables[key] = value;

        var stdout = new MemoryStream();
        var stderr = new StringBuilder();

        process.OutputDataReceived += null; // we read the raw stream instead, to preserve bytes exactly.

        process.Start();

        using var registration = cancellationToken.Register(() =>
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) { /* already exited */ }
        });

        var stdoutTask = process.StandardOutput.BaseStream.CopyToAsync(stdout, cancellationToken);

        var stderrTask = Task.Run(async () =>
        {
            var buffer = new char[4096];
            int read;
            while ((read = await process.StandardError.ReadAsync(buffer, cancellationToken)) > 0)
            {
                var chunk = new string(buffer, 0, read);
                stderr.Append(chunk);
                onProgress?.Invoke(chunk);
            }
        }, cancellationToken);

        if (input is not null)
        {
            await process.StandardInput.BaseStream.WriteAsync(input, cancellationToken);
            process.StandardInput.Close();
        }

        await Task.WhenAll(stdoutTask, stderrTask);
        await process.WaitForExitAsync(cancellationToken);

        if (!allowed.Contains(process.ExitCode))
        {
            throw new GitException(
                command: string.Join(" ", arguments.Take(2)),
                exitCode: process.ExitCode,
                stderr: stderr.ToString());
        }

        return stdout.ToArray();
    }

    public async Task<string> RunStringAsync(IReadOnlyList<string> arguments, bool readOnly = false, CancellationToken cancellationToken = default)
    {
        var data = await RunAsync(arguments, readOnly, cancellationToken: cancellationToken);
        return Encoding.UTF8.GetString(data);
    }

    private static IEnumerable<KeyValuePair<string, string>> BuildEnvironment(bool readOnly)
    {
        var env = new Dictionary<string, string>();
        foreach (System.Collections.DictionaryEntry entry in Environment.GetEnvironmentVariables())
            env[(string)entry.Key] = (string?)entry.Value ?? "";

        env["LC_ALL"] = "en_US.UTF-8";
        env["LANG"] = "en_US.UTF-8";
        env["GIT_TERMINAL_PROMPT"] = "0";
        env["GIT_PAGER"] = "cat";
        env["GIT_EDITOR"] = "true";
        if (!env.ContainsKey("GIT_SSH_COMMAND") && !env.ContainsKey("GIT_SSH"))
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes";
        if (readOnly) env["GIT_OPTIONAL_LOCKS"] = "0";

        return env;
    }
}

// MARK: - Byte splitting helpers

internal static class ByteSplitting
{
    /// <summary>
    /// Splits on a single byte. Done at the byte level, not on text lines, because CRLF files and
    /// odd (non-UTF8-safe) names must survive untouched (see Parsers.swift / PORTING.md).
    /// </summary>
    public static List<string> SplitBytes(ReadOnlySpan<byte> data, byte separator)
    {
        var result = new List<string>();
        int start = 0;
        for (int i = 0; i < data.Length; i++)
        {
            if (data[i] == separator)
            {
                result.Add(Encoding.UTF8.GetString(data[start..i]));
                start = i + 1;
            }
        }
        result.Add(Encoding.UTF8.GetString(data[start..]));
        return result;
    }

    public static List<string> SplitBytes(string value, byte separator) =>
        SplitBytes(Encoding.UTF8.GetBytes(value), separator);
}
