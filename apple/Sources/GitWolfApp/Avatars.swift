import AppKit
import CryptoKit
import GitWolfCore
import Observation
import SwiftUI

/// Downloads and caches profile pictures (memory and a folder under Caches). Sends no credentials.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()
    private let memory = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<Data?, Never>] = [:]
    private let folder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("GitWolf/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func file(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(digest)
    }

    func image(for url: URL) async -> NSImage? {
        if let hit = memory.object(forKey: url as NSURL) { return hit }
        if let task = inflight[url] { return await task.value.flatMap { NSImage(data: $0) } }
        let path = file(for: url)
        // The task carries the encoded bytes (Sendable); the image is built back on the main actor.
        let task = Task<Data?, Never> {
            // A picture fetched in the last week is good enough.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
               let modified = attrs[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 7 * 86_400,
               let data = try? Data(contentsOf: path), NSImage(data: data) != nil { return data }
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("GitWolf", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000,
                  NSImage(data: data) != nil else { return nil }
            try? data.write(to: path, options: .atomic)
            return data
        }
        inflight[url] = task
        let bytes = await task.value
        inflight[url] = nil
        guard let bytes, let image = NSImage(data: bytes) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }
}

/// Works out which profile picture belongs to each commit author in one repository.
@MainActor @Observable
final class AvatarProvider {
    private(set) var urls: [String: URL] = [:]
    @ObservationIgnored private var attempted: [String: Date] = [:]
    @ObservationIgnored private var running = 0
    @ObservationIgnored private var waiting: [(email: String, sha: String)] = []
    /// Asks the hosting platform (set by the repository store).
    @ObservationIgnored var lookup: (@Sendable (String, String) async -> URL?)?

    func url(forEmail email: String) -> URL? { urls[email.lowercased()] }

    /// Starts finding the picture for `email`, using commit `sha` as the example to look up.
    func request(email: String, sha: String) {
        let key = email.lowercased()
        guard !key.isEmpty, urls[key] == nil else { return }
        if let last = attempted[key], Date().timeIntervalSince(last) < 600 { return }
        attempted[key] = Date()
        if let url = AvatarURLs.fromNoreply(email: email) { urls[key] = url; return }
        guard lookup != nil else { return }
        waiting.append((key, sha))
        pump()
    }

    private func pump() {
        while running < 3, !waiting.isEmpty, let lookup {
            let next = waiting.removeFirst()
            running += 1
            Task {
                let url = await lookup(next.sha, next.email)
                if let url { urls[next.email] = url }
                running -= 1
                pump()
            }
        }
    }
}

/// A person's profile picture from the platform, over their coloured initials until it loads.
struct AvatarView: View {
    let name: String
    let email: String
    var size: CGFloat = 26
    /// A commit by this person, used to ask the platform who they are.
    var sha: String?
    /// A picture URL the platform already gave (for example on a comment).
    var url: URL?
    @Environment(AvatarProvider.self) private var provider: AvatarProvider?
    @State private var image: NSImage?

    private var resolved: URL? { url ?? provider?.url(forEmail: email) }

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        ZStack {
            Circle().fill(avatarColor(for: email.isEmpty ? name : email))
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            if let image {
                Image(nsImage: image).resizable().scaledToFill().clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
        .task(id: resolved) {
            guard let resolved else { image = nil; return }
            image = await AvatarImages.shared.image(for: resolved)
        }
        .onAppear {
            if url == nil, let sha { provider?.request(email: email, sha: sha) }
        }
        .help(name)
    }
}
