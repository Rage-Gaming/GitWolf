import AppKit
import GitWolfCore
import SwiftUI

/// Resolves one conflicted file: pick ours, theirs or both for each conflict block, then save and
/// stage it. Files without markers (deleted on one side, binary) get whole-file choices.
struct ConflictResolverView: View {
    let store: RepositoryStore
    let path: String

    @State private var stages: ConflictStages?
    @State private var document: ConflictDocument?
    @State private var choices: [Int: ConflictChoice] = [:]
    @State private var loaded = false

    private var blocks: [ConflictBlock] { document?.blocks ?? [] }
    private var resolvedCount: Int { blocks.filter { choices[$0.id] != nil }.count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !loaded {
                Spacer(); ProgressView().controlSize(.small); Spacer()
            } else if let document, !blocks.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(blocks) { block in
                            BlockCard(block: block, index: block.id + 1, total: blocks.count,
                                      choice: choices[block.id]) { choices[block.id] = $0 }
                        }
                    }
                    .padding(14)
                }
                Divider()
                footer(document)
            } else {
                wholeFile
            }
        }
        .task(id: path) { await load() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.pink)
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty { Text(dir + "/").foregroundStyle(.secondary).lineLimit(1).truncationMode(.head) }
            Text((path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
            Spacer()
            if let stages {
                Text(stages.title).font(.caption.weight(.semibold)).foregroundStyle(.pink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.pink.opacity(0.12), in: Capsule())
            }
        }
        .font(.system(.callout, design: .monospaced).weight(.medium))
        .padding(.horizontal, 14).frame(height: 40)
    }

    private func footer(_ document: ConflictDocument) -> some View {
        HStack(spacing: 8) {
            Text("\(resolvedCount) of \(blocks.count) resolved").foregroundStyle(.secondary)
            Spacer()
            Button("All Ours") { setAll(.ours) }
            Button("All Theirs") { setAll(.theirs) }
            Button("Mark as Resolved") {
                store.resolveConflict(path, content: document.render(choices))
            }
            .buttonStyle(.borderedProminent)
            .disabled(resolvedCount < blocks.count || store.isBusy)
            .help(resolvedCount < blocks.count ? "Choose a side for every conflict first" : "Save the file and stage it")
        }
        .controlSize(.regular)
        .padding(.horizontal, 14).frame(height: 48)
    }

    private func setAll(_ choice: ConflictChoice) {
        for block in blocks { choices[block.id] = choice }
    }

    /// No markers to edit: deleted on one side, a binary file, or markers already removed.
    private var wholeFile: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.badge.gearshape").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text(stages?.title ?? "Conflict").font(.title3.weight(.semibold))
            Text(explanation).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            HStack {
                if stages?.ours ?? true { Button("Keep Ours") { store.resolveConflict(path, taking: .ours) } }
                if stages?.theirs ?? true { Button("Keep Theirs") { store.resolveConflict(path, taking: .theirs) } }
                if stages?.ours == false || stages?.theirs == false {
                    Button("Delete File", role: .destructive) { store.resolveConflict(path, taking: .delete) }
                }
                if stages?.hasContentConflict == true { Button("Mark as Resolved") { store.stage([path]) } }
            }
            .disabled(store.isBusy)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var explanation: String {
        switch (stages?.ours, stages?.theirs) {
        case (true?, false?): "Your side changed this file, but the other side deleted it. Keep your version or delete the file."
        case (false?, true?): "Your side deleted this file, but the other side changed it. Keep their version or delete the file."
        default:
            if stages?.hasContentConflict == true {
                "This file has no conflict markers to edit (it may be binary or already edited). Pick a side or mark it resolved."
            } else { "Choose how to resolve this file." }
        }
    }

    private func load() async {
        loaded = false
        let repo = store.repo
        stages = try? await repo.conflictStages(path)
        document = (try? await repo.conflictDocument(path)) ?? nil
        choices = [:]
        loaded = true
    }
}

private struct BlockCard: View {
    let block: ConflictBlock
    let index: Int
    let total: Int
    let choice: ConflictChoice?
    let onChoose: (ConflictChoice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Conflict \(index) of \(total)").font(.callout.weight(.semibold))
                if choice != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                ForEach([(ConflictChoice.ours, "Ours"), (.theirs, "Theirs"), (.both, "Both"), (.bothReversed, "Both, Theirs First")], id: \.0) { value, title in
                    Button(title) { onChoose(value) }
                        .buttonStyle(ChoiceButtonStyle(on: choice == value))
                }
            }
            .padding(.horizontal, 12).frame(height: 38)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                side(block.oursLabel, "Ours", block.ours, .blue, dimmed: choice == .theirs)
                Divider()
                side(block.theirsLabel, "Theirs", block.theirs, .green, dimmed: choice == .ours)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(choice == nil ? Color.pink.opacity(0.5) : Color.primary.opacity(0.1)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func side(_ label: String, _ role: String, _ lines: [String], _ tint: Color, dimmed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(role).fontWeight(.semibold).foregroundStyle(tint)
                Text(label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .font(.caption).padding(.horizontal, 10).frame(height: 26)
            Text(lines.isEmpty ? "(empty)" : lines.joined(separator: "\n").replacingOccurrences(of: "\r", with: ""))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(tint.opacity(0.08))
        .opacity(dimmed ? 0.4 : 1)
    }
}

private struct ChoiceButtonStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).frame(height: 24)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? Theme.brand : Color.primary.opacity(configuration.isPressed ? 0.16 : 0.07), in: Capsule())
    }
}
