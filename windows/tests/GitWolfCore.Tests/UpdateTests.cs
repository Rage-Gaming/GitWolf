using System.IO.Compression;
using System.Net;
using System.Text;
using GitWolf.Core;
using Xunit;

namespace GitWolfCore.Tests;

public class UpdateTests
{
    private static readonly string Key = Convert.ToBase64String(Enumerable.Range(1, 32).Select(i => (byte)i).ToArray());
    private static readonly string Public = UpdateSigning.PublicKey(Key);
    private const string Url = "https://github.com/ipuppyyt/GitWolf/releases/download/v1.2.0/GitWolf.zip";

    private static AppVersion V(string text)
    {
        Assert.True(AppVersion.TryParse(text, out var version));
        return version;
    }

    [Fact]
    public void VersionsCompare()
    {
        Assert.True(V("1.10.0") > V("1.9.9"));
        Assert.Equal(V("v2.0"), V("2.0.0"));
        Assert.Equal(V("2.0").GetHashCode(), V("2.0.0.0").GetHashCode());
        Assert.True(V("2.0.0-beta.2") < V("2.0.0"));
        Assert.True(V("2.0.0") > V("2.0.0-beta.2"));
        Assert.True(V("2.0.0-beta.2") < V("2.0.0-beta.10"));
        Assert.False(AppVersion.TryParse("dev", out _));
        Assert.False(AppVersion.TryParse("1..2", out _));
        Assert.False(AppVersion.TryParse(null, out _));
        Assert.Equal(1_002_003, V("1.2.3").BuildNumber);
    }

    private static AppcastItem Item(string version, string url = Url, long length = 10, string signature = "c2ln") =>
        new(version, V(version).BuildNumber.ToString(), url, length, signature,
            Date: DateTimeOffset.FromUnixTimeSeconds(1_700_000_000));

    private static IReadOnlyList<AppcastItem> Read(string xml) =>
        Appcast.Parse(new MemoryStream(Encoding.UTF8.GetBytes(xml)));

    [Fact]
    public void FeedRoundTripsAndKeepsNewestFirst()
    {
        IReadOnlyList<AppcastItem> feed = [];
        foreach (var version in new[] { "0.1.0", "0.3.0", "0.2.0" }) feed = Appcast.Merge(Item(version), feed);
        Assert.Equal(["0.3.0", "0.2.0", "0.1.0"], feed.Select(i => i.Version));
        feed = Appcast.Merge(Item("0.2.0") with { Notes = "fixed <a> & ]]> ünï 🐺" }, feed);
        Assert.Equal(3, feed.Count);

        var xml = Appcast.Render(feed);
        Assert.Contains("sparkle:edSignature=\"c2ln\"", xml);
        Assert.Contains("<sparkle:shortVersionString>0.3.0<", xml);
        Assert.Contains("<pubDate>Tue, 14 Nov 2023 22:13:20 +0000</pubDate>", xml);
        Assert.Equal(feed, Read(xml));
    }

    [Fact]
    public void FeedIsCappedAndEscaped()
    {
        IReadOnlyList<AppcastItem> feed = [];
        for (var i = 0; i < 30; i++) feed = Appcast.Merge(Item($"1.0.{i}", "https://x/a?b=1&c=\"2\""), feed);
        Assert.Equal(Appcast.MaxItems, feed.Count);
        Assert.Equal("1.0.29", feed[0].Version);
        Assert.Equal("https://x/a?b=1&c=\"2\"", Read(Appcast.Render(feed))[0].Url);
    }

    [Fact]
    public void FeedRefusesDocumentTypesAndBrokenXml()
    {
        Assert.Throws<FormatException>(() => Read(
            "<?xml version=\"1.0\"?><!DOCTYPE r [<!ENTITY a SYSTEM \"file:///c:/x\">]><r>&a;</r>"));
        Assert.Throws<FormatException>(() => Read("<rss><channel>"));
    }

    [Fact]
    public void SignaturesVerifyOnlyTheSignedBytes()
    {
        byte[] data = [1, 2, 3];
        var signature = UpdateSigning.Sign(data, Key);
        Assert.True(UpdateSigning.Verify(data, signature, Public));
        Assert.False(UpdateSigning.Verify([1, 2, 4], signature, Public));
        Assert.False(UpdateSigning.Verify(data, "not base64!", Public));
        Assert.False(UpdateSigning.Verify(data, signature, Updater.ReleaseKey));
        Assert.Throws<FormatException>(() => UpdateSigning.Sign(data, "c2hvcnQ="));
    }

    [Fact]
    public void SigningMatchesTheEd25519TestVector()
    {
        // RFC 8032, test 1: an empty message.
        var seed = Convert.ToBase64String(Convert.FromHexString(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"));
        Assert.Equal(Convert.FromHexString("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"),
            Convert.FromBase64String(UpdateSigning.PublicKey(seed)));
        Assert.StartsWith("e5564300c360ac72", Convert.ToHexString(
            Convert.FromBase64String(UpdateSigning.Sign([], seed))).ToLowerInvariant());
    }

    [Fact]
    public void PublishingSignsAndKeepsEarlierReleases()
    {
        byte[] archive = [9, 8, 7];
        var date = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var first = UpdatePublisher.Publish(archive, "1.0.0", Url, "one", null, Key, date, Public);
        var second = UpdatePublisher.Publish(archive, "1.1.0", Url, "two", first, Key, date, Public);
        var items = Read(second);
        Assert.Equal(["1.1.0", "1.0.0"], items.Select(i => i.Version));
        Assert.True(UpdateSigning.Verify(archive, items[0].Signature, Public));
        Assert.Equal(3, items[0].Length);
        // The wrong key, a broken earlier feed and an odd version all stop the release.
        Assert.Throws<FormatException>(() => UpdatePublisher.Publish(archive, "1.0.0", Url, "", null, Key, date));
        Assert.Throws<FormatException>(() => UpdatePublisher.Publish(archive, "1.0.0", Url, "", "<", Key, date, Public));
        Assert.Throws<FormatException>(() => UpdatePublisher.Publish(archive, "1.0", Url, "", null, Key, date, Public));
    }

    private sealed class Server(Func<Uri, HttpResponseMessage> answer) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) =>
            Task.FromResult(answer(request.RequestUri!));
    }

    private static Updater Serving(byte[] feed, byte[]? archive = null, string current = "1.0.0") =>
        new(new HttpClient(new Server(url => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ByteArrayContent(url == Updater.Feed ? feed : archive ?? []),
        })), V(current), Public, new Version(10, 0, 19045));

    private static byte[] Feed(params AppcastItem[] items) =>
        Encoding.UTF8.GetBytes(Appcast.Sign(Appcast.Render(items), Key));

    [Fact]
    public async Task ChecksOfferOnlyNewerInstallableReleases()
    {
        var feed = Feed(
            Item("9.0.0", "http://github.com/a.zip"),
            Item("8.0.0", "https://example.com/a.zip"),
            Item("7.0.0", length: Updater.MaxArchiveBytes + 1),
            Item("6.0.0", signature: ""),
            Item("5.0.0") with { MinimumSystemVersion = "11.0" },
            Item("4.0.0", "https://user@github.com/a.zip"),
            Item("1.1.0"),
            Item("1.2.0"));
        Assert.Equal("1.2.0", (await Serving(feed).CheckAsync())?.Version);
        Assert.Null(await Serving(feed, current: "1.2.0").CheckAsync());
    }

    [Fact]
    public async Task ChecksReportFailures()
    {
        await Assert.ThrowsAsync<UpdateException>(() => Serving("nonsense"u8.ToArray()).CheckAsync());
        await Assert.ThrowsAsync<UpdateException>(() => Serving(new byte[Appcast.MaxBytes + 1]).CheckAsync());
        var missing = new Updater(new HttpClient(new Server(_ => new(HttpStatusCode.NotFound))), V("1.0.0"));
        await Assert.ThrowsAsync<UpdateException>(() => missing.CheckAsync());
    }

    [Fact]
    public async Task OnlyASignedFeedIsRead()
    {
        var signed = Appcast.Sign(Appcast.Render([Item("1.2.0")]), Key);
        var other = Convert.ToBase64String(new byte[32]);
        Assert.Single(Read(signed));
        foreach (var feed in new[]
        {
            Appcast.Render([Item("1.2.0")]),
            signed.Replace("1.2.0", "1.3.0"),
            signed + "<!-- more -->",
            Appcast.Sign(Appcast.Render([Item("1.2.0")]), other),
            "<!-- gitwolf-signature: ",
        })
            await Assert.ThrowsAsync<UpdateException>(() => Serving(Encoding.UTF8.GetBytes(feed)).CheckAsync());
        // The release tool won't sign an edited feed again.
        Assert.Throws<FormatException>(() => UpdatePublisher.Publish([1], "1.3.0", Url, "",
            signed.Replace("1.2.0", "1.1.0"), Key, DateTimeOffset.UtcNow, Public));
    }

    [Fact]
    public async Task DownloadsAreVerified()
    {
        byte[] archive = [1, 2, 3, 4];
        var item = Item("1.2.0", length: 4, signature: UpdateSigning.Sign(archive, Key));
        Assert.Equal(V("1.2.0"), (await Serving([], archive).DownloadAsync(item)).Version);
        await Assert.ThrowsAsync<UpdateException>(() => Serving([], [1, 2, 3, 5]).DownloadAsync(item));
        await Assert.ThrowsAsync<UpdateException>(() => Serving([], [1, 2, 3]).DownloadAsync(item));
        await Assert.ThrowsAsync<UpdateException>(() => Serving([], [1, 2, 3, 4, 5]).DownloadAsync(item));
        // Never a downgrade, even if asked for.
        await Assert.ThrowsAsync<UpdateException>(() => Serving([], archive, "2.0.0").DownloadAsync(item));
    }

    private static byte[] Zip(params (string Name, string Text)[] files)
    {
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
            foreach (var (name, text) in files)
            {
                using var writer = new StreamWriter(zip.CreateEntry(name).Open());
                writer.Write(text);
            }
        return stream.ToArray();
    }

    /// <summary>A folder as unpacked by a user, with a file of their own in it.</summary>
    private static string Installed()
    {
        var folder = Directory.CreateTempSubdirectory("gitwolf-update-").FullName;
        File.WriteAllText(Path.Combine(folder, UpdateInstaller.Executable), "1.0.0");
        File.WriteAllText(Path.Combine(folder, "library.dll"), "old");
        File.WriteAllText(Path.Combine(folder, "notes.txt"), "mine");
        return folder;
    }

    private static VerifiedUpdate Release(params (string Name, string Text)[] files) => new(V("1.2.0"), Zip(files));

    private static string Text(string folder, string name) => File.ReadAllText(Path.Combine(folder, name));

    [Fact]
    public void InstallReplacesOnlyTheReleasesFiles()
    {
        var folder = Installed();
        try
        {
            var update = Release((UpdateInstaller.Executable, "1.2.0"), ("library.dll", "new"), ("sub/added.txt", "a"));
            UpdateInstaller.Install(update, folder, File.ReadAllText);
            Assert.Equal("1.2.0", Text(folder, UpdateInstaller.Executable));
            Assert.Equal("new", Text(folder, "library.dll"));
            Assert.Equal("a", Text(folder, "sub/added.txt"));
            Assert.Equal("mine", Text(folder, "notes.txt"));
            UpdateInstaller.CleanUp(folder);
            Assert.Empty(Directory.GetDirectories(folder, ".gitwolf-update-*"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Theory]
    [InlineData(UpdateInstaller.Executable, "1.1.0")]
    [InlineData("GitWolf", "1.2.0")]
    [InlineData("../outside.txt", "x")]
    public void InstallRefusesWhatIsNotTheRelease(string name, string text)
    {
        var folder = Installed();
        try
        {
            Assert.Throws<UpdateException>(() =>
                UpdateInstaller.Install(Release((name, text)), folder, File.ReadAllText));
            Assert.Equal("1.0.0", Text(folder, UpdateInstaller.Executable));
            Assert.Equal("old", Text(folder, "library.dll"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }

    [Fact]
    public void InstallRestoresEverythingWhenAFileIsLocked()
    {
        var folder = Installed();
        try
        {
            File.WriteAllText(Path.Combine(folder, "zz.dll"), "held");
            var update = Release((UpdateInstaller.Executable, "1.2.0"), ("library.dll", "new"), ("zz.dll", "new"));
            // Opened without sharing deletion, so it cannot be renamed.
            using (new FileStream(Path.Combine(folder, "zz.dll"), FileMode.Open, FileAccess.Read, FileShare.Read))
                Assert.Throws<UpdateException>(() => UpdateInstaller.Install(update, folder, File.ReadAllText));
            Assert.Equal("1.0.0", Text(folder, UpdateInstaller.Executable));
            Assert.Equal("old", Text(folder, "library.dll"));
            Assert.Equal("held", Text(folder, "zz.dll"));
        }
        finally
        {
            Directory.Delete(folder, recursive: true);
        }
    }
}
