import GitWolfCore
import SwiftUI

/// Form for opening a pull / merge request from the current branch, or a new issue.
struct NewCollabSheet: View {
    let store: RepositoryStore
    let kind: CollabKind
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var base = ""
    @State private var draft = false
    @State private var working = false
    @State private var error: String?

    private var collab: CollabStore { store.collab(kind) }
    private var head: String { store.status.branch ?? "" }
    private var word: String { kind == .pullRequest ? (store.webLinks?.pullRequestsWord ?? "Pull Request") : "Issue" }
    private var bases: [String] {
        var names = store.localBranches.map(\.name).filter { $0 != head }
        for b in store.remoteBranches {
            let short = b.shortName
            if short != head, short != "HEAD", !names.contains(short) { names.append(short) }
        }
        return names
    }
    private var needsPush: Bool { kind == .pullRequest && (store.status.upstream == nil || store.status.ahead > 0) }
    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !working && (kind == .issue || (!head.isEmpty && !base.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(word)").font(.system(size: 17, weight: .semibold, design: .rounded))
            if kind == .pullRequest {
                HStack(spacing: 8) {
                    chip(head.isEmpty ? "detached HEAD" : head)
                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $base) { ForEach(bases, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().fixedSize()
                }
            }
            TextField("Title", text: $title)
                .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            TextField("Description (Markdown)", text: $text, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(6...12).padding(12)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if kind == .pullRequest {
                Toggle("Open as draft", isOn: $draft)
                if needsPush {
                    Label(store.status.upstream == nil ? "This branch will be pushed first." : "Your latest commits will be pushed first.",
                          systemImage: "arrow.up.circle").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create \(word)", action: create).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(22).frame(width: 520)
        .onAppear(perform: prefill)
    }

    private func chip(_ name: String) -> some View {
        Text(name).font(.system(.callout, design: .monospaced)).lineLimit(1)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// Title and description come from the branch's own commits, like the websites do.
    private func prefill() {
        guard kind == .pullRequest else { return }
        let preferred = ["main", "master", "develop", "trunk"]
        base = bases.first(where: preferred.contains) ?? bases.first ?? ""
        let own = store.commits.prefix { $0.id != store.localBranches.first(where: { $0.name == base })?.hash }
        if let only = own.first, own.count == 1 {
            title = only.subject
        } else {
            title = head.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
                .split(separator: "/").last.map(String.init)?.capitalizedFirst ?? head
        }
    }

    private func create() {
        working = true
        error = nil
        let status = store.status, remotes = store.remotes, repo = store.repo
        let title = title.trimmingCharacters(in: .whitespaces), body = text, base = base, head = head, draft = draft
        Task {
            do {
                if needsPush { try await repo.push(status: status, remotes: remotes) }
                try await collab.create(title: title, body: body, head: head, base: base, draft: draft)
                store.mode = kind == .pullRequest ? .pullRequests : .issues
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
