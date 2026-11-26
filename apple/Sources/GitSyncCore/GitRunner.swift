import Foundation

/// A failed git invocation.
public struct GitError: Error, LocalizedError, Sendable {
    public let command: String
    public let exitCode: Int32
    public let stderr: String

    public var errorDescription: String? {
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "git \(command) failed (exit code \(exitCode))" : message
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Runs the system `git` binary. Every call is an independent process, so it is safe to
/// call concurrently from any context.
public struct GitRunner: Sendable {
    public let workingDirectory: URL
    public let gitPath: String

    public init(workingDirectory: URL, gitPath: String = "/usr/bin/git") {
        self.workingDirectory = workingDirectory
        self.gitPath = gitPath
    }

    /// - Parameters:
    ///   - readOnly: Sets `GIT_OPTIONAL_LOCKS=0` so background refreshes never touch the
    ///     index and therefore never trigger file-watcher feedback loops or lock errors.
    ///   - allowedExitCodes: Exit codes treated as success (e.g. `git diff --no-index` returns 1).
    @discardableResult
    public func run(
        _ arguments: [String],
        readOnly: Bool = false,
        allowedExitCodes: Set<Int32> = [0],
        input: Data? = nil
    ) async throws -> Data {
        let directory = workingDirectory
        let path = gitPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let data = try Self.execute(
                        path: path, directory: directory, arguments: arguments,
                        readOnly: readOnly, allowed: allowedExitCodes, input: input)
                    continuation.resume(returning: data)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func runString(_ arguments: [String], readOnly: Bool = false) async throws -> String {
        let data = try await run(arguments, readOnly: readOnly)
        return String(decoding: data, as: UTF8.self)
    }

    private static func environment(readOnly: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        if env["GIT_SSH_COMMAND"] == nil && env["GIT_SSH"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        // GUI apps launch with a minimal PATH; hooks and credential helpers often need more.
        let extra = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = (env["PATH"].map { $0 + ":" } ?? "/usr/bin:/bin:/usr/sbin:/sbin:") + extra
        if readOnly { env["GIT_OPTIONAL_LOCKS"] = "0" }
        return env
    }

    private static func execute(
        path: String, directory: URL, arguments: [String],
        readOnly: Bool, allowed: Set<Int32>, input: Data?
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment(readOnly: readOnly)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = input != nil ? Pipe() : nil
        process.standardInput = stdin ?? FileHandle.nullDevice

        try process.run()

        let errorBox = DataBox()
        let group = DispatchGroup()
        let errorHandle = stderr.fileHandleForReading
        group.enter()
        DispatchQueue.global().async {
            errorBox.data = errorHandle.readDataToEndOfFile()
            group.leave()
        }
        if let stdin, let input {
            let writer = stdin.fileHandleForWriting
            DispatchQueue.global().async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        guard allowed.contains(process.terminationStatus) else {
            throw GitError(
                command: arguments.prefix(2).joined(separator: " "),
                exitCode: process.terminationStatus,
                stderr: String(decoding: errorBox.data, as: UTF8.self))
        }
        return output
    }
}

// MARK: - Byte splitting helpers

/// Splits on a single byte. Done at the byte level because `String.split(separator: "\n")`
/// does not match "\r\n" (a single Character in Swift), which would corrupt CRLF files.
func splitBytes(_ data: Data, _ separator: UInt8) -> [String] {
    data.split(separator: separator, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
}

func splitBytes(_ string: String, _ separator: UInt8) -> [String] {
    string.utf8.split(separator: separator, omittingEmptySubsequences: false)
        .map { String(decoding: $0, as: UTF8.self) }
}
