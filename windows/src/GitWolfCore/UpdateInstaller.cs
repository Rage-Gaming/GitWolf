using System.Diagnostics;
using System.IO.Compression;

namespace GitWolf.Core;

/// <summary>
/// Puts a verified release in place of the running one. Files are renamed aside, which Windows allows for
/// programs that are running, and renamed back if anything fails. Only files the release contains are
/// touched, because the app may have been unpacked into a folder that holds other things.
/// </summary>
public static class UpdateInstaller
{
    public const string Executable = "GitWolf.App.exe";
    private const string Staging = ".gitwolf-update-new";
    private const string Previous = ".gitwolf-update-old";

    public static void Install(VerifiedUpdate update, string folder, Func<string, string?>? versionOf = null)
    {
        var staging = Path.Combine(folder, Staging);
        var previous = Path.Combine(folder, Previous);
        try
        {
            Delete(staging);
            Delete(previous);
            Directory.CreateDirectory(staging);
            using (var archive = new MemoryStream(update.Archive, writable: false))
                // Refuses entries that would land outside the folder.
                ZipFile.ExtractToDirectory(archive, staging);
            Check(staging, update.Version, versionOf ?? (file => FileVersionInfo.GetVersionInfo(file).FileVersion));
            Swap(staging, folder, previous);
        }
        catch (UnauthorizedAccessException e)
        {
            throw new UpdateException(
                "GitWolf can’t replace its files. Download the new version from the releases page.", e);
        }
        catch (Exception e) when (e is IOException or InvalidDataException)
        {
            throw new UpdateException("The update couldn’t be installed. The current version was kept.", e);
        }
        finally
        {
            TryDelete(staging);
        }
    }

    /// <summary>Removes what an earlier update set aside. Files still in use are left for next time.</summary>
    public static void CleanUp(string folder)
    {
        TryDelete(Path.Combine(folder, Staging));
        TryDelete(Path.Combine(folder, Previous));
    }

    /// <summary>
    /// The signature covers the archive, not what the feed says about it, so an older release or another
    /// platform's archive offered as this one is refused here.
    /// </summary>
    private static void Check(string staging, AppVersion expected, Func<string, string?> versionOf)
    {
        var executable = Path.Combine(staging, Executable);
        if (!File.Exists(executable) || !AppVersion.TryParse(versionOf(executable), out var actual)
            || !actual.Equals(expected))
            throw new UpdateException("The download isn’t the release it claims to be, so it was not installed.");
    }

    private static void Swap(string staging, string folder, string previous)
    {
        // What has been moved so far, so it can be moved back.
        var moves = new Stack<(string From, string To)>();
        void Move(string from, string to)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(to)!);
            File.Move(from, to);
            moves.Push((from, to));
        }
        try
        {
            foreach (var file in Directory.EnumerateFiles(staging, "*", SearchOption.AllDirectories).ToList())
            {
                var name = Path.GetRelativePath(staging, file);
                var target = Path.Combine(folder, name);
                if (File.Exists(target)) Move(target, Path.Combine(previous, name));
                Move(file, target);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            while (moves.TryPop(out var move))
            {
                try
                {
                    File.Move(move.To, move.From);
                }
                catch (Exception undo) when (undo is IOException or UnauthorizedAccessException)
                {
                    Trace.TraceError($"Restoring a file after a failed update failed: {undo.GetType().Name}");
                }
            }
            throw;
        }
    }

    private static void Delete(string path)
    {
        if (Directory.Exists(path)) Directory.Delete(path, recursive: true);
    }

    private static void TryDelete(string path)
    {
        try
        {
            Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Trace.TraceInformation($"An update folder is still in use: {e.GetType().Name}");
        }
    }
}
