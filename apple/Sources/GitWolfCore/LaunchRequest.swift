import Foundation

/// Works out which folder an "open this" request from outside the app means: a folder or file dropped on the app
/// or passed by the `gitwolf` command, or a `gitwolf://open?path=/some/folder` link.
public enum LaunchRequest {
    public static let scheme = "gitwolf"

    /// The local folder to open, or nil when the URL names none. A file means the folder that holds it.
    public static func folder(from url: URL) -> URL? {
        let path: String
        if url.isFileURL {
            path = url.path
        } else if url.scheme?.lowercased() == scheme, url.host?.lowercased() == "open",
                  let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "path" })?.value,
                  value.hasPrefix("/") {
            path = value
        } else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        let url = URL(fileURLWithPath: path)
        return isDirectory.boolValue ? url : url.deletingLastPathComponent()
    }

    /// A link that opens `folder` in GitWolf.
    public static func link(for folder: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = scheme; parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "path", value: folder.path)]
        return parts.url
    }
}
