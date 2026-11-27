using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public sealed class CommitHelperTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitwolf-commit-{Guid.NewGuid()}");
    private GitRunner Git => new(_dir);
    private GitRepository Repo => new(_dir);

    public CommitHelperTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        try
        {
            foreach (var file in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(_dir, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Left in the temporary folder.
        }
    }

    private void Write(string file, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(Path.Combine(_dir, file))!);
        File.WriteAllText(Path.Combine(_dir, file), text);
    }

    private async Task InitAsync()
    {
        await Git.RunAsync(["init", "-b", "main"]);
        await Git.RunAsync(["config", "user.name", "Tester"]);
        await Git.RunAsync(["config", "user.email", "t@example.com"]);
        await Git.RunAsync(["config", "commit.gpgsign", "false"]);
        await Git.RunAsync(["config", "core.autocrlf", "false"]);
        await Git.RunAsync(["config", "core.hooksPath", ".git/hooks"]);
    }

    private async Task<string> LogAsync() => await Git.RunStringAsync(["log", "--format=%s"]);

    [Fact]
    public async Task ARefusingHookIsReportedAndCanBeSkipped()
    {
        await InitAsync();
        Write(".git/hooks/pre-commit", "#!/bin/sh\necho 'lint says no'\nexit 1\n");
        Write("a.txt", "a\n");
        await Repo.StageAllAsync();

        var error = await Assert.ThrowsAsync<HookFailedException>(() => Repo.CommitAsync("first", false));
        Assert.Equal("pre-commit", error.Hook);
        Assert.Contains("lint says no", error.Output);

        await Repo.CommitAsync("first", false, skipHooks: true);
        Assert.Contains("first", await LogAsync());
    }

    [Fact]
    public async Task GitsOwnFailuresAreNotBlamedOnAHook()
    {
        await InitAsync();
        Write(".git/hooks/pre-commit", "#!/bin/sh\nexit 0\n");

        await Assert.ThrowsAsync<GitException>(() => Repo.CommitAsync("empty", false));
    }

    [Fact]
    public void TerminalColoursAreRemovedFromHookOutput() =>
        Assert.Equal("red", HookDiagnosis.Diagnose("\u001b[31mred\u001b[0m", ["commit-msg"])?.Output);

    [Fact]
    public async Task SigningSettingsAreRead()
    {
        await InitAsync();
        await Git.RunAsync(["config", "user.signingkey", "ABC"]);

        var config = await Repo.SigningConfigAsync();

        Assert.False(config.SignsByDefault);
        Assert.True(config.IsConfigured);
    }

    [Theory]
    [InlineData("add thing", "feat", null, "feat: add thing")]
    [InlineData("fix(old)!: bug\n\nbody", "docs", "ui", "docs(ui): bug\n\nbody")]
    [InlineData("", "chore", null, "chore: ")]
    public void PrefixesAreSetOrReplaced(string message, string type, string? scope, string expected) =>
        Assert.Equal(expected, CommitMessage.ApplyPrefix(type, scope, message));

    [Fact]
    public void LongSubjectsAndScopesAreFound()
    {
        Assert.Null(CommitMessage.LongSubject(new string('a', 72) + "\n" + new string('b', 100)));
        Assert.Equal(73, CommitMessage.LongSubject(new string('a', 73)));
        Assert.Equal(["a", "b"], CommitMessage.SuggestedScopes(["a/x", "root", "b/y", "a/z"]));
    }

    [Fact]
    public async Task TemplateAndRecentMessagesCanBeReused()
    {
        await InitAsync();
        Assert.Empty(await Repo.RecentMessagesAsync());
        Assert.Null(await Repo.CommitTemplateAsync());
        Write("template.txt", "# comment\nSubject\n");
        await Git.RunAsync(["config", "commit.template", "template.txt"]);
        await Git.RunAsync(["commit", "--allow-empty", "-m", "same"]);
        await Git.RunAsync(["commit", "--allow-empty", "-m", "same"]);

        Assert.Equal("Subject", await Repo.CommitTemplateAsync());
        Assert.Equal(["same"], await Repo.RecentMessagesAsync());
    }

    [Fact]
    public async Task IgnoreRulesHideOnlyWhatTheyName()
    {
        await InitAsync();
        Write(".gitignore", "bin");
        Write("src/a[1].log", "x");
        Write("src/a1.log", "x");
        var exact = IgnoreRules.Options("src/a[1].log")[0];

        Assert.True(await Repo.AddIgnoreRuleAsync(exact.Pattern));
        Assert.False(await Repo.AddIgnoreRuleAsync(exact.Pattern));

        var untracked = (await Repo.StatusAsync()).Untracked.Select(f => f.Path).ToList();
        Assert.DoesNotContain("src/a[1].log", untracked);
        Assert.Contains("src/a1.log", untracked);
        Assert.StartsWith("bin\n", File.ReadAllText(Path.Combine(_dir, ".gitignore")));
    }

    [Fact]
    public async Task ALocalRuleAndUntrackingKeepTheFile()
    {
        await InitAsync();
        Write("secret.env", "x");
        await Repo.StageAllAsync();
        await Repo.CommitAsync("add", false);

        await Repo.AddIgnoreRuleAsync("/secret.env", local: true);
        await Repo.StopTrackingAsync("secret.env");

        Assert.True(File.Exists(Path.Combine(_dir, "secret.env")));
        Assert.False(File.Exists(Path.Combine(_dir, ".gitignore")));
        Assert.Empty((await Repo.StatusAsync()).Untracked);
        Assert.Single((await Repo.StatusAsync()).Staged);
    }
}
