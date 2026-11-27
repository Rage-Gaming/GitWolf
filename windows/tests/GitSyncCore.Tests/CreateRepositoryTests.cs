using GitSync.Core;
using Xunit;

namespace GitSyncCore.Tests;

public sealed class CreateRepositoryTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"gitsync-create-{Guid.NewGuid()}");

    public CreateRepositoryTests() => Directory.CreateDirectory(_dir);

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

    [Fact]
    public async Task ANewRepositoryCanBeCloned()
    {
        var source = await GitRepository.CreateAsync(_dir, "source", "trunk");
        var folder = await GitRepository.CloneAsync(source, _dir, "copy");

        Assert.True(Directory.Exists(Path.Combine(folder, ".git")));
        Assert.Equal("trunk", (await new GitRepository(source).StatusAsync()).Branch);
    }

    [Theory]
    [InlineData("..")]
    [InlineData(".")]
    [InlineData("a/b")]
    [InlineData("a\\b")]
    [InlineData("C:x")]
    [InlineData("")]
    public async Task NamesThatLeaveTheChosenFolderAreRefused(string name)
    {
        await Assert.ThrowsAsync<GitException>(() => GitRepository.CreateAsync(_dir, name, "main"));
        await Assert.ThrowsAsync<GitException>(() => GitRepository.CloneAsync("https://example.invalid/r.git", _dir, name));
    }

    [Fact]
    public async Task TransportHelpersCannotRunCommands()
    {
        var marker = Path.Combine(_dir, "ran").Replace('\\', '/');

        await Assert.ThrowsAsync<GitException>(
            () => GitRepository.CloneAsync($"ext::sh -c \"touch {marker}\"", _dir, "x"));

        Assert.False(File.Exists(marker));
    }

    [Fact]
    public async Task AFolderThatIsNotEmptyIsNotOverwritten()
    {
        Directory.CreateDirectory(Path.Combine(_dir, "full"));
        File.WriteAllText(Path.Combine(_dir, "full", "keep.txt"), "keep");

        await Assert.ThrowsAsync<GitException>(() => GitRepository.CreateAsync(_dir, "full", "main"));
    }
}
