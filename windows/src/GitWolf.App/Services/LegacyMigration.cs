namespace GitWolf.App.Services;

/// <summary>
/// The app used to be called GitSync. On the first launch as GitWolf, the old settings folder is moved
/// over so open repositories and preferences carry across. The old name is kept here on purpose.
/// </summary>
internal static class LegacyMigration
{
    public static void Run()
    {
        try
        {
            var root = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var oldDir = Path.Combine(root, "GitSync");
            var newDir = Path.Combine(root, "GitWolf");
            if (Directory.Exists(oldDir) && !Directory.Exists(newDir)) Directory.Move(oldDir, newDir);
        }
        catch (IOException)
        {
            // Leave the old folder alone; the app starts with default settings.
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
