import Foundation

/// A user-defined shell command that runs at a repository's root, e.g. `code .` or `make test`.
/// The command is run by `/bin/sh -c`; the repository is passed through the environment
/// (`GITSYNC_REPO`, `GITSYNC_BRANCH`) rather than substituted into the text, so paths and branch
/// names can never be interpreted as shell syntax.
public struct CustomAction: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var command: String

    public init(id: UUID = UUID(), name: String, command: String) {
        self.id = id; self.name = name; self.command = command
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct CustomActionResult: Equatable, Sendable {
    public let exitCode: Int32
    public let output: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum CustomActionRunner {
    /// Runs `action` with `root` as the working directory and waits for it to finish.
    public static func run(_ action: CustomAction, root: URL, branch: String?) async -> CustomActionResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", action.command]
            process.currentDirectoryURL = root
            var env = ProcessInfo.processInfo.environment
            env["GITSYNC_REPO"] = root.path
            env["GITSYNC_BRANCH"] = branch ?? ""
            process.environment = env
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let box = OutputBox()
            pipe.fileHandleForReading.readabilityHandler = { handle in box.append(handle.availableData) }
            process.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                box.append(pipe.fileHandleForReading.readDataToEndOfFile())
                continuation.resume(returning: CustomActionResult(exitCode: p.terminationStatus, output: box.string))
            }
            do { try process.run() } catch {
                continuation.resume(returning: CustomActionResult(exitCode: 127, output: error.localizedDescription))
            }
        }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.lock(); data.append(more); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
