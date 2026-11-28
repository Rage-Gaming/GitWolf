using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public sealed class RepoIconTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("gitwolf-icons-").FullName;

    public void Dispose() => Directory.Delete(_dir, recursive: true);

    [Fact]
    public void SetReplaceAndClear()
    {
        var icons = new RepoIcons();
        Assert.Null(icons.Set("/a", RepoIcon.OfSymbol("star")));
        Assert.Equal(RepoIcon.OfSymbol("star"), icons.Icon("/a"));
        Assert.Null(icons.Set("/a", RepoIcon.OfImage("one.png")));
        // Replacing an image reports the file that is now unused.
        Assert.Equal("one.png", icons.Set("/a", RepoIcon.OfSymbol("flame")));
        Assert.Null(icons.Set("/b", RepoIcon.OfImage("two.png")));
        Assert.Null(icons.Set("/b", RepoIcon.OfImage("two.png")));
        Assert.Equal("two.png", icons.Set("/b", null));
        Assert.Null(icons.Icon("/b"));
    }

    [Fact]
    public void PrunesMissingRepositories()
    {
        var icons = new RepoIcons();
        icons.Set("/gone", RepoIcon.OfImage("gone.png"));
        icons.Set("/kept", RepoIcon.OfSymbol("star"));
        icons.SetTint("/gone", RepoTint.Teal);
        Assert.Equal(["gone.png"], icons.Prune(p => p == "/kept"));
        Assert.Null(icons.Icon("/gone"));
        Assert.Null(icons.Tint("/gone"));
        Assert.NotNull(icons.Icon("/kept"));
    }

    [Fact]
    public void IconsAndColoursAreSavedAndReplacedImagesDeleted()
    {
        var store = new RepoIconStore(_dir);
        var name = RepoIconStore.NewImageName();
        File.WriteAllText(store.ImagePath(name), "png");
        Assert.True(store.Set(@"C:\Repo", RepoIcon.OfImage(name)));
        Assert.True(store.SetTint(@"C:\Repo", RepoTint.Pink));

        var reloaded = new RepoIconStore(_dir);
        // Windows paths match whatever their case.
        Assert.Equal(RepoIcon.OfImage(name), reloaded.Icons.Icon(@"c:\repo"));
        Assert.Equal(RepoTint.Pink, reloaded.Icons.Tint(@"c:\repo"));

        Assert.True(reloaded.Set(@"C:\Repo", null));
        Assert.False(File.Exists(reloaded.ImagePath(name)));
        Assert.Null(new RepoIconStore(_dir).Icons.Icon(@"C:\Repo"));
    }

    [Theory]
    [InlineData(@"..\..\victim.png")]
    [InlineData(@"C:\victim.png")]
    [InlineData("victim.png")]
    public void AnEditedSettingsFileCannotNameAnotherFile(string name)
    {
        var json = System.Text.Json.JsonSerializer.Serialize(name);
        File.WriteAllText(Path.Combine(_dir, "repo-icons.json"),
            $$$"""{"Icons":{"/a":{"Symbol":"star","Image":{{{json}}}}},"Tints":{"/a":"Blue"}}""");
        var store = new RepoIconStore(_dir);
        Assert.Null(store.Icons.Icon("/a"));
        Assert.Equal(RepoTint.Blue, store.Icons.Tint("/a"));
        Assert.Throws<ArgumentException>(() => store.ImagePath(name));
    }

    [Fact]
    public void ADamagedSettingsFileStartsEmpty()
    {
        File.WriteAllText(Path.Combine(_dir, "repo-icons.json"), "{not json");
        Assert.Empty(new RepoIconStore(_dir).Icons.Icons);
    }
}
