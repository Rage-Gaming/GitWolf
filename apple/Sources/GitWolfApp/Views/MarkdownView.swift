import SwiftUI

/// Renders the Markdown used in pull request and issue descriptions: headings, lists, task lists,
/// quotes, code blocks, rules and inline styling. Tables and raw HTML are shown as plain text.
struct MarkdownView: View {
    let source: String

    private enum Block: Identifiable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(depth: Int, marker: String, text: String)
        case task(depth: Int, done: Bool, text: String)
        case quote(String)
        case code(String)
        case rule
        case table([String])

        var id: String { UUID().uuidString }
    }

    var body: some View {
        let blocks = Self.parse(source)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in view(for: block) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(for block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(.system(size: [22, 19, 16.5, 15, 14, 13][min(level, 6) - 1], weight: .semibold, design: .rounded))
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let text):
            inline(text)
        case .bullet(let depth, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 14, alignment: .trailing)
                inline(text)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .task(let depth, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Theme.brand : .secondary)
                inline(text).foregroundStyle(done ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote(let text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.secondary.opacity(0.4)).frame(width: 3)
                inline(text).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.system(size: 12, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(rows.joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).padding(10)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
    }

    // MARK: Parsing

    private static func parse(_ source: String) -> [Block] {
        // Drop HTML comments (PR templates are full of them).
        let cleaned = source.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var blocks: [Block] = []
        var paragraph: [String] = []
        var lines = cleaned.components(separatedBy: "\n")[...]

        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }

        while let raw = lines.popFirst() {
            let line = raw.trimmingCharacters(in: .init(charactersIn: " \t"))
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }

            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                flush()
                let fence = String(line.prefix(3))
                var code: [String] = []
                while let next = lines.popFirst() {
                    if next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    code.append(next)
                }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if line.isEmpty {
                flush()
            } else if let h = line.firstMatch(of: /^(#{1,6})\s+(.*?)\s*#*$/) {
                flush(); blocks.append(.heading(h.1.count, String(h.2)))
            } else if line.wholeMatch(of: /(-{3,}|\*{3,}|_{3,})/) != nil {
                flush(); blocks.append(.rule)
            } else if line.hasPrefix(">") {
                flush()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let t = line.firstMatch(of: /^[-*+]\s+\[([ xX])\]\s+(.*)$/) {
                flush(); blocks.append(.task(depth: indent / 2, done: t.1 != " ", text: String(t.2)))
            } else if let b = line.firstMatch(of: /^[-*+]\s+(.*)$/) {
                flush(); blocks.append(.bullet(depth: indent / 2, marker: "•", text: String(b.1)))
            } else if let n = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                flush(); blocks.append(.bullet(depth: indent / 2, marker: "\(n.1).", text: String(n.2)))
            } else if line.hasPrefix("|") {
                flush()
                var rows = [line]
                while let next = lines.first, next.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(next.trimmingCharacters(in: .whitespaces)); lines.removeFirst()
                }
                blocks.append(.table(rows))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
