using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public sealed class GitPathTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("gitwolf-path-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void TheLauncherIsSkippedOnlyWhenTheRealProgramIsThere()
    {
        var launcher = Path.Combine(_dir, "cmd", "git.exe");
        Assert.Equal(launcher, GitRunner.WithoutLauncher(launcher));

        var real = Path.Combine(_dir, "mingw64", "bin", "git.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(real)!);
        File.WriteAllText(real, "");
        Assert.Equal(real, GitRunner.WithoutLauncher(launcher));
        var other = Path.Combine(_dir, "bin", "git.exe");
        Assert.Equal(other, GitRunner.WithoutLauncher(other));
    }
}
