using System.Globalization;
using System.Text;

namespace GitWolf.Core;

/// <summary>Signs a release archive and adds it to the feed, for the release workflow.</summary>
public static class UpdatePublisher
{
    /// <summary>
    /// The new feed. Refuses a key that doesn't match <paramref name="publicKey"/>: apps already installed
    /// would reject everything signed with it.
    /// </summary>
    public static string Publish(byte[] archive, string version, string url, string notes, string? previousFeed,
        string privateKey, DateTimeOffset date, string publicKey = Updater.ReleaseKey)
    {
        if (!AppVersion.TryParse(version, out var parsed) || parsed.Prerelease is not null || parsed.Numbers.Count != 3)
            throw new FormatException("The version must look like 1.2.3.");
        if (UpdateSigning.PublicKey(privateKey) != publicKey)
            throw new FormatException("The private key doesn’t match the public key built into the app.");
        // A feed that exists but can't be read stops the release instead of losing the earlier entries.
        // Entries are only carried over from a feed this key signed, so an edited one isn't signed again.
        if (!string.IsNullOrWhiteSpace(previousFeed)
            && !Appcast.IsSigned(Encoding.UTF8.GetBytes(previousFeed), publicKey))
            throw new FormatException("The previous feed isn’t signed with the release key.");
        IReadOnlyList<AppcastItem> existing = string.IsNullOrWhiteSpace(previousFeed)
            ? []
            : Appcast.Parse(new MemoryStream(Encoding.UTF8.GetBytes(previousFeed)));
        var item = new AppcastItem(parsed.ToString(), parsed.BuildNumber.ToString(CultureInfo.InvariantCulture),
            url, archive.LongLength, UpdateSigning.Sign(archive, privateKey), notes.Trim(), date);
        return Appcast.Sign(Appcast.Render(Appcast.Merge(item, existing)), privateKey);
    }
}
