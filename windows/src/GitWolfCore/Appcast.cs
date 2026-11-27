using System.Globalization;
using System.Security;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace GitWolf.Core;

/// <summary>One release in an update feed that the in-app updater reads.</summary>
public sealed record AppcastItem(
    string Version,
    string Build,
    string Url,
    long Length,
    string Signature,
    string Notes = "",
    DateTimeOffset Date = default,
    string MinimumSystemVersion = "10.0.17763");

/// <summary>
/// The update feed, in the same format as macOS's. Windows has its own file (appcast-windows.xml) and
/// writes release notes as plain text. Ported from Appcast.swift.
/// </summary>
public static class Appcast
{
    public const int MaxItems = 20;
    /// <summary>Far more than <see cref="MaxItems"/> releases need.</summary>
    public const int MaxBytes = 1024 * 1024;

    private const string Sparkle = "http://www.andymatuschak.org/xml-namespaces/sparkle";
    private const string DateFormat = "ddd, dd MMM yyyy HH:mm:ss";

    /// <summary>The whole feed, newest first.</summary>
    public static string Render(IEnumerable<AppcastItem> items, string title = "GitWolf",
        string link = "https://github.com/ipuppyyt/GitWolf")
    {
        var xml = new StringBuilder()
            .Append("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n")
            .Append($"<rss version=\"2.0\" xmlns:sparkle=\"{Sparkle}\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\n")
            .Append("  <channel>\n")
            .Append($"    <title>{Escape(title)}</title>\n")
            .Append($"    <link>{Escape(link)}</link>\n")
            .Append($"    <description>{Escape(title)} updates</description>\n")
            .Append("    <language>en</language>\n");
        foreach (var item in items)
        {
            var date = item.Date.ToUniversalTime().ToString(DateFormat, CultureInfo.InvariantCulture) + " +0000";
            xml.Append("    <item>\n")
                .Append($"      <title>Version {Escape(item.Version)}</title>\n")
                .Append($"      <pubDate>{date}</pubDate>\n")
                .Append($"      <sparkle:version>{Escape(item.Build)}</sparkle:version>\n")
                .Append($"      <sparkle:shortVersionString>{Escape(item.Version)}</sparkle:shortVersionString>\n")
                .Append("      <sparkle:minimumSystemVersion>")
                .Append(Escape(item.MinimumSystemVersion))
                .Append("</sparkle:minimumSystemVersion>\n");
            if (item.Notes.Length > 0)
                xml.Append("      <description><![CDATA[")
                    .Append(Clean(item.Notes).Replace("]]>", "]]]]><![CDATA[>"))
                    .Append("]]></description>\n");
            xml.Append($"      <enclosure url=\"{Escape(item.Url)}\" ")
                .Append($"length=\"{item.Length.ToString(CultureInfo.InvariantCulture)}\" ")
                .Append("type=\"application/octet-stream\" ")
                .Append($"sparkle:edSignature=\"{Escape(item.Signature)}\"/>\n")
                .Append("    </item>\n");
        }
        return xml.Append("  </channel>\n</rss>\n").ToString();
    }

    /// <summary>Adds a release: the same version is replaced, newest first, at most <see cref="MaxItems"/>.</summary>
    public static IReadOnlyList<AppcastItem> Merge(AppcastItem item, IEnumerable<AppcastItem> existing) =>
        existing.Where(i => i.Version != item.Version).Append(item)
            .OrderByDescending(i => AppVersion.TryParse(i.Version, out var v) ? v.BuildNumber : 0)
            .Take(MaxItems).ToList();

    /// <summary>
    /// Reads a feed. Throws <see cref="FormatException"/> when it isn't well formed; document types are
    /// refused, so no entities are expanded and nothing else is fetched.
    /// </summary>
    public static IReadOnlyList<AppcastItem> Parse(Stream xml)
    {
        var settings = new XmlReaderSettings
        {
            DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxBytes,
        };
        XDocument document;
        try
        {
            using var reader = XmlReader.Create(xml, settings);
            document = XDocument.Load(reader);
        }
        catch (XmlException e)
        {
            throw new FormatException("The update feed is not valid XML.", e);
        }
        XNamespace sparkle = Sparkle;
        var items = new List<AppcastItem>();
        foreach (var item in document.Descendants("item"))
        {
            string Value(XName name) => item.Element(name)?.Value.Trim() ?? "";
            var version = Value(sparkle + "shortVersionString");
            if (version.Length == 0) continue;
            var enclosure = item.Element("enclosure");
            _ = long.TryParse((string?)enclosure?.Attribute("length"), NumberStyles.None,
                CultureInfo.InvariantCulture, out var length);
            _ = DateTimeOffset.TryParseExact(Value("pubDate").Replace(" +0000", ""), DateFormat,
                CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date);
            items.Add(new AppcastItem(version, Value(sparkle + "version"),
                (string?)enclosure?.Attribute("url") ?? "", length,
                (string?)enclosure?.Attribute(sparkle + "edSignature") ?? "",
                item.Element("description")?.Value ?? "", date, Value(sparkle + "minimumSystemVersion")));
        }
        return items;
    }

    /// <summary>Drops characters XML cannot hold, so one stray byte in the notes can't break the feed.</summary>
    private static string Clean(string text)
    {
        var result = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            if (XmlConvert.IsXmlChar(text[i])) result.Append(text[i]);
            else if (i + 1 < text.Length && XmlConvert.IsXmlSurrogatePair(text[i + 1], text[i]))
                result.Append(text[i]).Append(text[++i]);
        }
        return result.ToString();
    }

    private static string Escape(string text) => SecurityElement.Escape(Clean(text)) ?? "";
}
