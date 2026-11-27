using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

// Ported from CustomActionTests in apple/Tests/GitWolfCoreTests/GitWolfCoreTests.swift.
public sealed class CustomActionTests : IDisposable
{
    // A folder name that would break a command it was pasted into.
    private readonly string _root = Directory.CreateTempSubdirectory("gitwolf action; & (x) ").FullName;
    private static readonly string Git = new GitRunner(Environment.SystemDirectory).GitPath;

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A program started by a test may still be using the folder.
        }
    }

    private Task<CustomActionResult> Run(string command, string? branch = null) =>
        CustomActionRunner.RunAsync(new CustomAction(Guid.NewGuid(), "test", command), _root, branch, Git);

    [Fact]
    public async Task RunsAtTheRepositoryRootWithTheEnvironment()
    {
        var result = await Run(
            "echo here > marker; echo \"branch=$GITWOLF_BRANCH\"; echo \"repo=$GITWOLF_REPO\"", "feature/x y");
        Assert.True(result.Succeeded, result.Output);
        Assert.True(File.Exists(Path.Combine(_root, "marker")));
        Assert.Contains("branch=feature/x y", result.Output);
        Assert.Contains($"repo={_root}", result.Output);
    }

    [Fact]
    public async Task BranchNamesAreNeverRunAsCommands()
    {
        const string branch = "x&echo${IFS}INJECTED;$(echo SUB)`echo TICK`";
        var result = await Run("echo \"$GITWOLF_BRANCH\"; echo $GITWOLF_BRANCH", branch);
        Assert.True(result.Succeeded, result.Output);
        Assert.Equal(branch, result.Output.Split('\n')[0]);
        Assert.DoesNotContain("\nINJECTED", result.Output);
    }

    [Fact]
    public async Task TheCommandIsNotChangedOnTheWay()
    {
        var result = await Run("printf '%s|' \"a b\" '*' 'c:\\d\\' \"é\"\nprintf second");
        Assert.True(result.Succeeded, result.Output);
        Assert.Equal("a b|*|c:\\d\\|é|second", result.Output);
    }

    [Fact]
    public async Task ReportsFailure()
    {
        var result = await Run("echo oops >&2; exit 3");
        Assert.Equal(3, result.ExitCode);
        Assert.Contains("oops", result.Output);
    }

    [Fact]
    public async Task KeepsOnlyTheEndOfLongOutput()
    {
        var result = await Run("for i in $(seq 1 5000); do echo \"line $i\"; done");
        Assert.True(result.Output.Length <= CustomActionRunner.KeptOutput);
        Assert.EndsWith("line 5000\n", result.Output);
    }

    [Fact]
    public async Task DoesNotWaitForProgramsLeftRunningOrForInput()
    {
        var started = DateTime.UtcNow;
        var result = await Run("read answer; sleep 20 & echo done");
        Assert.Contains("done", result.Output);
        Assert.True(DateTime.UtcNow - started < TimeSpan.FromSeconds(15));
    }

    [Fact]
    public async Task SaysWhenThereIsNoShell()
    {
        var result = await CustomActionRunner.RunAsync(
            new CustomAction(Guid.NewGuid(), "x", "echo"), _root, null, Path.Combine(_root, "cmd", "git.exe"));
        Assert.Equal(127, result.ExitCode);
    }

    [Fact]
    public void Validation()
    {
        Assert.False(new CustomAction(Guid.NewGuid(), " ", "ls").IsValid);
        Assert.False(new CustomAction(Guid.NewGuid(), "x", "").IsValid);
        Assert.True(new CustomAction(Guid.NewGuid(), "x", "ls").IsValid);
    }

    [Fact]
    public void OpensWithoutPuttingTheFolderInACommandLine()
    {
        var terminal = OpenIn.Terminal(_root, localAppData: _root);
        Assert.EndsWith("powershell.exe", terminal.FileName);
        Assert.Empty(terminal.ArgumentList);
        Assert.Equal(_root, terminal.WorkingDirectory);

        var apps = Directory.CreateDirectory(Path.Combine(_root, "Microsoft", "WindowsApps")).FullName;
        File.WriteAllText(Path.Combine(apps, "wt.exe"), "");
        var windowsTerminal = OpenIn.Terminal(_root, localAppData: _root);
        Assert.Equal(["-d", "."], windowsTerminal.ArgumentList);
        Assert.Equal(_root, windowsTerminal.WorkingDirectory);

        Assert.Equal([_root], OpenIn.Explorer(_root).ArgumentList);
        Assert.Equal([_root], OpenIn.Editor(@"C:\editor.exe", _root).ArgumentList);
    }
}
