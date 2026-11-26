import CoreServices
import Foundation

/// Watches a working tree (including `.git`) with FSEvents and emits a coalesced signal
/// whenever something git-relevant changes. Object-database churn and lock files are filtered
/// out so our own read-only commands can never cause a refresh loop.
public final class FileWatcher: @unchecked Sendable {
    public let events: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "gitsync.filewatcher", qos: .utility)

    public init(root: URL, latency: TimeInterval = 0.25) {
        var cont: AsyncStream<Void>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { cont = $0 }
        continuation = cont

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.handle(paths)
        }

        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        let watched = [root.resolvingSymlinksInPath().path] as CFArray
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, watched,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit { stop() }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        continuation.finish()
    }

    private func handle(_ paths: [String]) {
        if paths.contains(where: Self.isRelevant) { continuation.yield(()) }
    }

    static func isRelevant(_ path: String) -> Bool {
        if path.contains("/.git/objects") || path.contains("/.git/lfs") { return false }
        if path.hasSuffix(".lock") || path.hasSuffix(".DS_Store") { return false }
        if path.hasSuffix("/.git/FETCH_HEAD") || path.contains("/.git/logs/") { return false }
        return true
    }
}
