using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace GitWolf.Core;

/// <summary>
/// A user-defined shell command that runs at a repository's root, e.g. <c>code .</c> or <c>make test</c>.
/// The repository is passed through the environment (<c>GITWOLF_REPO</c>, <c>GITWOLF_BRANCH</c>) rather
/// than substituted into the text, so paths and branch names are never read as shell syntax.
/// Ported from CustomActions.swift.
/// </summary>
public sealed record CustomAction(Guid Id, string Name, string Command)
{
    public bool IsValid => !string.IsNullOrWhiteSpace(Name) && !string.IsNullOrWhiteSpace(Command);
}

public sealed record CustomActionResult(int ExitCode, string Output)
{
    public bool Succeeded => ExitCode == 0;
}

public static class CustomActionRunner
{
    /// <summary>Only the end of a command's output is kept, however much it prints.</summary>
    public const int KeptOutput = 8192;
    /// <summary>How long output is still read after the shell exits; a program it started may hold on.</summary>
    private static readonly TimeSpan Drain = TimeSpan.FromSeconds(1);

    /// <summary>
    /// The shell that ships with Git for Windows, found beside <paramref name="gitPath"/>. Not cmd.exe: it
    /// expands <c>%NAME%</c> before parsing, so a branch name could run as a command.
    /// </summary>
    public static string? FindShell(string gitPath)
    {
        if (!OperatingSystem.IsWindows()) return "/bin/sh";
        if (!Path.IsPathFullyQualified(gitPath)) return null;
        // git.exe is in cmd, bin or mingw64\bin below the installation.
        var folder = Path.GetDirectoryName(gitPath);
        for (var up = 0; up < 3 && folder is not null; up++)
        {
            folder = Path.GetDirectoryName(folder);
            if (folder is null) break;
            var shell = Path.Combine(folder, "bin", "sh.exe");
            if (File.Exists(shell)) return shell;
        }
        return null;
    }

    /// <summary>Runs the action with <paramref name="root"/> as the working directory and waits for it.</summary>
    public static async Task<CustomActionResult> RunAsync(CustomAction action, string root, string? branch,
        string gitPath, CancellationToken token = default)
    {
        if (FindShell(gitPath) is not { } shell)
            return new(127, "The shell that comes with Git for Windows wasn’t found next to the Git executable.");
        var start = new ProcessStartInfo(shell)
        {
            WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        start.ArgumentList.Add("-c");
        // The command arrives in a variable, so Windows argument quoting can't change it.
        start.ArgumentList.Add("eval \"$GITWOLF_COMMAND\"");
        start.Environment["GITWOLF_COMMAND"] = action.Command;
        start.Environment["GITWOLF_REPO"] = root;
        start.Environment["GITWOLF_BRANCH"] = branch ?? "";

        var output = new StringBuilder();
        async Task ReadAsync(StreamReader reader)
        {
            var buffer = new char[2048];
            int read;
            while ((read = await reader.ReadAsync(buffer, token).ConfigureAwait(false)) > 0)
                lock (output)
                {
                    output.Append(buffer, 0, read);
                    if (output.Length > KeptOutput * 2) output.Remove(0, output.Length - KeptOutput);
                }
        }

        try
        {
            using var process = Process.Start(start)!;
            process.StandardInput.Close();
            var reading = Task.WhenAll(ReadAsync(process.StandardOutput), ReadAsync(process.StandardError));
            try
            {
                await process.WaitForExitAsync(token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                process.Kill(entireProcessTree: true);
                throw;
            }
            if (await Task.WhenAny(reading, Task.Delay(Drain, token)).ConfigureAwait(false) == reading)
                await reading.ConfigureAwait(false);
            else
                // Disposing the process ends the abandoned reads; their errors are of no interest.
                _ = reading.ContinueWith(t => _ = t.Exception, TaskScheduler.Default);
            lock (output)
            {
                var text = output.Length > KeptOutput
                    ? output.ToString(output.Length - KeptOutput, KeptOutput) : output.ToString();
                return new(process.ExitCode, text);
            }
        }
        catch (Exception e) when (e is Win32Exception or IOException)
        {
            return new(127, e.Message);
        }
    }
}
