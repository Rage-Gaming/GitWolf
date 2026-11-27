using System.Diagnostics;

namespace GitWolf.Core;

/// <summary>
/// Opens a repository in File Explorer, a terminal or an editor. Programs are started by full path and
/// never through a shell, so nothing in a folder name is read as a command.
/// </summary>
public static class OpenIn
{
    private static string Folder(Environment.SpecialFolder folder) => Environment.GetFolderPath(folder);

    /// <summary>The folder itself is the one argument.</summary>
    public static ProcessStartInfo Explorer(string root)
    {
        var start = new ProcessStartInfo(Path.Combine(Folder(Environment.SpecialFolder.Windows), "explorer.exe"));
        start.ArgumentList.Add(Path.GetFullPath(root));
        return start;
    }

    /// <summary>
    /// Windows Terminal when installed, else PowerShell. The folder is only ever the working directory:
    /// Windows Terminal reads <c>;</c> in its arguments as the start of another command.
    /// </summary>
    public static ProcessStartInfo Terminal(string root, string? localAppData = null)
    {
        var windowsTerminal = Path.Combine(
            localAppData ?? Folder(Environment.SpecialFolder.LocalApplicationData),
            "Microsoft", "WindowsApps", "wt.exe");
        if (File.Exists(windowsTerminal))
        {
            var start = new ProcessStartInfo(windowsTerminal) { WorkingDirectory = root, UseShellExecute = false };
            start.ArgumentList.Add("-d");
            start.ArgumentList.Add(".");
            return start;
        }
        return new ProcessStartInfo(Path.Combine(Folder(Environment.SpecialFolder.System),
            "WindowsPowerShell", "v1.0", "powershell.exe"))
        {
            WorkingDirectory = root, UseShellExecute = false,
        };
    }

    /// <summary>Visual Studio Code, installed for this user or for everyone.</summary>
    public static string? FindDefaultEditor() => new[]
        {
            Path.Combine(Folder(Environment.SpecialFolder.LocalApplicationData), "Programs"),
            Folder(Environment.SpecialFolder.ProgramFiles),
        }
        .Select(root => Path.Combine(root, "Microsoft VS Code", "Code.exe"))
        .FirstOrDefault(File.Exists);

    public static ProcessStartInfo Editor(string editor, string root)
    {
        var start = new ProcessStartInfo(editor) { WorkingDirectory = root, UseShellExecute = false };
        start.ArgumentList.Add(Path.GetFullPath(root));
        return start;
    }
}
