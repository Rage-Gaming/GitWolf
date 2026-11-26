import Foundation

// MARK: - git status --porcelain=v2 -z --branch

enum StatusParser {
    static func parse(_ data: Data) -> WorkingStatus {
        var status = WorkingStatus()
        let tokens = splitBytes(data, 0)
        var i = 0

        func add(_ xy: Substring, path: String, original: String?) {
            let chars = Array(xy)
            guard chars.count == 2 else { return }
            if chars[0] != "." {
                status.staged.append(FileChange(path: path, originalPath: original, kind: ChangeKind(code: chars[0])))
            }
            if chars[1] != "." {
                status.unstaged.append(FileChange(path: path, originalPath: nil, kind: ChangeKind(code: chars[1])))
            }
        }

        while i < tokens.count {
            let token = tokens[i]
            i += 1
            guard let first = token.first else { continue }
            switch first {
            case "#":
                let parts = token.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3 else { continue }
                switch parts[1] {
                case "branch.oid":
                    status.headOID = parts[2] == "(initial)" ? nil : String(parts[2])
                case "branch.head":
                    status.branch = parts[2] == "(detached)" ? nil : String(parts[2])
                case "branch.upstream":
                    status.upstream = String(parts[2])
                case "branch.ab":
                    let ab = parts[2].split(separator: " ")
                    if ab.count == 2 {
                        status.ahead = Int(ab[0].dropFirst()) ?? 0
                        status.behind = Int(ab[1].dropFirst()) ?? 0
                    }
                default: break
                }
            case "1":
                let f = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if f.count == 9 { add(f[1], path: String(f[8]), original: nil) }
            case "2":
                let f = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = i < tokens.count ? tokens[i] : nil
                i += 1
                if f.count == 10 { add(f[1], path: String(f[9]), original: original) }
            case "u":
                let f = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if f.count == 11 {
                    status.conflicted.append(FileChange(path: String(f[10]), originalPath: nil, kind: .unmerged))
                }
            case "?":
                let path = String(token.dropFirst(2))
                status.untracked.append(FileChange(path: path, originalPath: nil, kind: .untracked))
            default:
                break
            }
        }
        return status
    }
}

// MARK: - git log

enum LogParser {
    static let format = "%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s"

    static func parse(_ data: Data, remotes: Set<String>) -> [Commit] {
        var commits: [Commit] = []
        for record in splitBytes(data, 0) {
            let f = splitBytes(record, 0x1f)
            guard f.count >= 7, !f[0].isEmpty else { continue }
            let hash = f[0].trimmingCharacters(in: .whitespacesAndNewlines)
            commits.append(Commit(
                hash: hash,
                parents: f[1].split(separator: " ").map(String.init),
                authorName: f[2],
                authorEmail: f[3],
                date: Date(timeIntervalSince1970: TimeInterval(f[4]) ?? 0),
                subject: f[6],
                refs: parseDecorations(f[5], remotes: remotes)))
        }
        return commits
    }

    /// Parses `%D`, e.g. `HEAD -> main, origin/main, tag: v1.0`.
    static func parseDecorations(_ raw: String, remotes: Set<String>) -> [RefLabel] {
        guard !raw.isEmpty else { return [] }
        var labels: [RefLabel] = []
        for part in raw.components(separatedBy: ", ") {
            if part.hasPrefix("HEAD -> ") {
                labels.append(RefLabel(name: String(part.dropFirst(8)), kind: .local, isCurrent: true))
            } else if part == "HEAD" {
                labels.append(RefLabel(name: "HEAD", kind: .head, isCurrent: true))
            } else if part.hasPrefix("tag: ") {
                labels.append(RefLabel(name: String(part.dropFirst(5)), kind: .tag, isCurrent: false))
            } else if let slash = part.firstIndex(of: "/"), remotes.contains(String(part[..<slash])) {
                if part.hasSuffix("/HEAD") { continue }
                labels.append(RefLabel(name: part, kind: .remote, isCurrent: false))
            } else {
                labels.append(RefLabel(name: part, kind: .local, isCurrent: false))
            }
        }
        return labels
    }
}

// MARK: - for-each-ref / stash

enum RefParser {
    static let branchFormat =
        "%(refname)%1f%(refname:short)%1f%(HEAD)%1f%(upstream:short)%1f%(upstream:track,nobracket)%1f%(objectname)"

    static func parseBranches(_ data: Data) -> [Branch] {
        var result: [Branch] = []
        for line in splitBytes(data, 10) where !line.isEmpty {
            let f = splitBytes(line, 0x1f)
            guard f.count >= 6 else { continue }
            let full = f[0]
            let isRemote = full.hasPrefix("refs/remotes/")
            if isRemote && full.hasSuffix("/HEAD") { continue }
            var ahead = 0, behind = 0
            for piece in f[4].components(separatedBy: ", ") {
                if piece.hasPrefix("ahead ") { ahead = Int(piece.dropFirst(6)) ?? 0 }
                if piece.hasPrefix("behind ") { behind = Int(piece.dropFirst(7)) ?? 0 }
            }
            result.append(Branch(
                name: f[1], fullRef: full, isRemote: isRemote, isCurrent: f[2] == "*",
                upstream: f[3].isEmpty ? nil : f[3], ahead: ahead, behind: behind, hash: f[5]))
        }
        return result
    }

    static func parseTags(_ data: Data) -> [GitTag] {
        splitBytes(data, 10).compactMap { line in
            let f = splitBytes(line, 0x1f)
            guard f.count >= 2, !f[0].isEmpty else { return nil }
            return GitTag(name: f[0], hash: f[1])
        }
    }

    static func parseStashes(_ data: Data) -> [Stash] {
        splitBytes(data, 10).compactMap { line in
            let f = splitBytes(line, 0x1f)
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return Stash(ref: f[0], message: f[1], date: Date(timeIntervalSince1970: TimeInterval(f[2]) ?? 0))
        }
    }

    /// `git diff --name-status -z` output.
    static func parseNameStatus(_ data: Data) -> [FileChange] {
        let tokens = splitBytes(data, 0)
        var changes: [FileChange] = []
        var i = 0
        while i < tokens.count {
            let code = tokens[i]
            i += 1
            guard let letter = code.first else { continue }
            let kind = ChangeKind(code: letter)
            if (kind == .renamed || kind == .copied), i + 1 < tokens.count {
                changes.append(FileChange(path: tokens[i + 1], originalPath: tokens[i], kind: kind))
                i += 2
            } else if i < tokens.count {
                changes.append(FileChange(path: tokens[i], originalPath: nil, kind: kind))
                i += 1
            }
        }
        return changes
    }
}

// MARK: - Unified diff

enum DiffParser {
    static func parse(_ data: Data, maxLines: Int) -> FileDiff {
        var diff = FileDiff.empty
        var oldNo = 0, newNo = 0
        var inHunk = false
        var hunk = -1

        func append(_ kind: DiffLine.Kind, old: Int? = nil, new: Int? = nil, text: String, raw: String) {
            diff.lines.append(DiffLine(
                id: diff.lines.count, kind: kind, hunkIndex: hunk,
                oldNumber: old, newNumber: new, text: text, raw: raw))
        }

        for raw in splitBytes(data, 10) {
            if raw.hasPrefix("@@") {
                inHunk = true
                if diff.lines.count >= maxLines { diff.isTruncated = true; break }
                hunk += 1
                if let (o, n, section) = parseHunkHeader(raw) {
                    oldNo = o; newNo = n
                    diff.hunks.append(DiffHunk(index: hunk, oldStart: o, newStart: n, section: section))
                } else {
                    diff.hunks.append(DiffHunk(index: hunk, oldStart: oldNo, newStart: newNo, section: ""))
                }
                append(.hunkHeader, text: raw, raw: raw)
                continue
            }
            if !inHunk {
                if raw.hasPrefix("Binary files") || raw.hasPrefix("GIT binary patch") { diff.isBinary = true }
                if !raw.isEmpty { diff.header.append(raw) }
                continue
            }
            guard let marker = raw.utf8.first else { continue }
            if diff.lines.count >= maxLines { diff.isTruncated = true; break }
            let body = String(raw.dropFirst())
            let text = body.hasSuffix("\r") ? String(body.dropLast()) : body
            switch marker {
            case UInt8(ascii: "+"):
                append(.addition, new: newNo, text: text, raw: body)
                newNo += 1
                diff.additions += 1
            case UInt8(ascii: "-"):
                append(.deletion, old: oldNo, text: text, raw: body)
                oldNo += 1
                diff.deletions += 1
            case UInt8(ascii: " "):
                append(.context, old: oldNo, new: newNo, text: text, raw: body)
                oldNo += 1
                newNo += 1
            case UInt8(ascii: "\\"):
                append(.note, text: raw, raw: raw)
            default:
                break
            }
        }
        return diff
    }

    /// `@@ -12,5 +14,7 @@ func foo()` → (12, 14, " func foo()")
    static func parseHunkHeader(_ header: String) -> (Int, Int, String)? {
        let parts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[1].hasPrefix("-"), parts[2].hasPrefix("+") else { return nil }
        guard let old = parts[1].dropFirst().split(separator: ",").first.flatMap({ Int($0) }),
              let new = parts[2].dropFirst().split(separator: ",").first.flatMap({ Int($0) })
        else { return nil }
        var section = ""
        if let close = header.range(of: " @@", range: header.index(header.startIndex, offsetBy: 2)..<header.endIndex) {
            section = String(header[close.upperBound...])
        }
        return (old, new, section)
    }
}
