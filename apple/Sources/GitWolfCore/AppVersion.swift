import Foundation

/// A dotted version such as `1.4.0` or `v2.0.0-beta.1`. Pre-releases sort before their release.
public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let numbers: [Int]
    public let prerelease: String?

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let core = parts.first, !core.isEmpty else { return nil }
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
        numbers = nums.compactMap { $0 }
        prerelease = parts.count > 1 ? parts[1] : nil
    }

    public var description: String { numbers.map(String.init).joined(separator: ".") + (prerelease.map { "-" + $0 } ?? "") }

    /// `2.0` equals `2.0.0`.
    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        let count = max(a.numbers.count, b.numbers.count)
        for i in 0..<count {
            let x = i < a.numbers.count ? a.numbers[i] : 0, y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x < y }
        }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil): return false
        case (_?, nil): return true
        case (nil, _?): return false
        case (let p?, let q?): return p.compare(q, options: .numeric) == .orderedAscending
        }
    }
}
