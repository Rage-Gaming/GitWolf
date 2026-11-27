import Foundation

/// One release in the update feed (`appcast.xml`) that the in-app updater reads.
public struct AppcastItem: Equatable, Sendable {
    public var version: String          // 1.2.3, shown to people
    public var build: String            // monotonically increasing, compared by the updater
    public var url: String              // the archive to download
    public var length: Int
    public var signature: String        // EdDSA, base64
    public var notesHTML: String
    public var date: Date
    public var minimumSystemVersion: String

    public init(version: String, build: String, url: String, length: Int, signature: String,
                notesHTML: String = "", date: Date = Date(), minimumSystemVersion: String = "15.0") {
        self.version = version; self.build = build; self.url = url; self.length = length
        self.signature = signature; self.notesHTML = notesHTML; self.date = date
        self.minimumSystemVersion = minimumSystemVersion
    }
}

public extension AppVersion {
    /// The build number the updater compares: 1.2.3 becomes 1002003, so versions always sort the same way.
    /// Pre-releases share their release's number; they are not offered through this feed.
    var buildNumber: Int {
        let n = numbers + [0, 0, 0]
        return n[0] * 1_000_000 + n[1] * 1_000 + n[2]
    }
}

public enum Appcast {
    public static let maxItems = 20

    /// The whole feed, newest first.
    public static func render(_ items: [AppcastItem], title: String = "GitWolf", link: String = "https://github.com/ipuppyyt/GitWolf") -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var out = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>\(escape(title))</title>
            <link>\(escape(link))</link>
            <description>\(escape(title)) updates</description>
            <language>en</language>

        """
        for item in items {
            out += """
                <item>
                  <title>Version \(escape(item.version))</title>
                  <pubDate>\(df.string(from: item.date))</pubDate>
                  <sparkle:version>\(escape(item.build))</sparkle:version>
                  <sparkle:shortVersionString>\(escape(item.version))</sparkle:shortVersionString>
                  <sparkle:minimumSystemVersion>\(escape(item.minimumSystemVersion))</sparkle:minimumSystemVersion>

            """
            if !item.notesHTML.isEmpty {
                out += "      <description><![CDATA[\(item.notesHTML.replacingOccurrences(of: "]]>", with: "]]]]><![CDATA[>"))]]></description>\n"
            }
            out += """
                  <enclosure url="\(escape(item.url))" length="\(item.length)" type="application/octet-stream" sparkle:edSignature="\(escape(item.signature))"/>
                </item>

            """
        }
        out += "  </channel>\n</rss>\n"
        return out
    }

    /// Adds a release to an existing feed: the same version is replaced, newest first, at most `maxItems`.
    public static func merging(_ new: AppcastItem, into existing: [AppcastItem]) -> [AppcastItem] {
        var all = existing.filter { $0.version != new.version } + [new]
        all.sort { (AppVersion($0.version)?.buildNumber ?? 0) > (AppVersion($1.version)?.buildNumber ?? 0) }
        return Array(all.prefix(maxItems))
    }

    /// Reads a feed written by `render`, so releases can be added without losing the earlier ones.
    public static func parse(_ xml: Data) -> [AppcastItem] {
        let parser = XMLParser(data: xml)
        let delegate = Reader()
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var notes = ""

        private static let df: DateFormatter = {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return df
        }()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            text = ""
            if name == "item" {
                current = AppcastItem(version: "", build: "", url: "", length: 0, signature: "")
                notes = ""
            } else if name == "enclosure", current != nil {
                current?.url = a["url"] ?? ""
                current?.length = Int(a["length"] ?? "") ?? 0
                current?.signature = a["sparkle:edSignature"] ?? ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { notes += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard current != nil else { return }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "sparkle:version": current?.build = value
            case "sparkle:shortVersionString": current?.version = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "pubDate": current?.date = Self.df.date(from: value) ?? Date(timeIntervalSince1970: 0)
            case "description": current?.notesHTML = notes
            case "item":
                if let item = current, !item.version.isEmpty { items.append(item) }
                current = nil
            default: break
            }
        }
    }
}
