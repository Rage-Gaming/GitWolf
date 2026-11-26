import AppKit
import GitSyncCore
import SwiftUI

private func stateColor(_ item: CollabItem) -> Color {
    if item.isDraft && item.state == .open { return .gray }
    switch item.state {
    case .open: return .green
    case .merged: return .purple
    case .closed: return .red
    }
}

private func stateIcon(_ item: CollabItem, kind: CollabKind) -> String {
    if kind == .issue { return item.state == .open ? "smallcircle.filled.circle" : "checkmark.circle.fill" }
    switch item.state {
    case .merged: return "arrow.triangle.merge"
    case .closed: return "xmark.circle.fill"
    case .open: return item.isDraft ? "pencil.circle" : "arrow.triangle.pull"
    }
}

private func stateWord(_ item: CollabItem) -> String {
    if item.isDraft && item.state == .open { return "Draft" }
    switch item.state {
    case .open: return "Open"
    case .merged: return "Merged"
    case .closed: return "Closed"
    }
}

private struct LabelChip: View {
    let name: String
    var body: some View {
        Text(name)
            .font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(avatarColor(for: name))
            .background(avatarColor(for: name).opacity(0.14), in: Capsule())
    }
}

// MARK: - List

struct CollabListView: View {
    @Bindable var store: RepositoryStore
    @Bindable var collab: CollabStore

    private var title: String { collab.kind == .pullRequest ? store.pullRequestsTitle : "Issues" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
                    Spacer()
                    if collab.canWrite {
                        Button { store.sheet = .newCollab(collab.kind) } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(collab.kind == .pullRequest ? "New \(store.webLinks?.pullRequestsWord ?? "Pull Request")" : "New Issue")
                    }
                    Button { collab.load() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reload")
                    .disabled(collab.isLoading)
                }
                Picker("", selection: $collab.filter) {
                    Text("Open").tag(CollabFilter.open)
                    Text("Closed").tag(CollabFilter.closed)
                    Text("All").tag(CollabFilter.all)
                }
                .pickerStyle(.segmented).labelsHidden()
                SearchField(text: $collab.query, prompt: "Search \(title.lowercased())")
            }
            .padding(12)
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { collab.loadIfNeeded() }
    }

    @ViewBuilder private var content: some View {
        if collab.isLoading && collab.items.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = collab.error, collab.items.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { collab.load() }
            }
        } else if collab.visibleItems.isEmpty {
            ContentUnavailableView(collab.query.isEmpty ? "Nothing Here" : "No Matches",
                                   systemImage: collab.kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle",
                                   description: Text(collab.query.isEmpty ? "No \(collab.filter == .all ? "" : collab.filter.rawValue + " ")\(title.lowercased()) found." : "Try a different search."))
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(collab.visibleItems) { item in
                        CollabRow(item: item, kind: collab.kind, selected: collab.selectedNumber == item.number) {
                            collab.selectedNumber = item.number
                        }
                    }
                    if collab.hasMore && collab.query.isEmpty {
                        Button { collab.loadMore() } label: {
                            HStack(spacing: 8) {
                                if collab.isLoading { ProgressView().controlSize(.small) }
                                Text("Load more").font(.callout.weight(.medium))
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(6)
            }
        }
    }
}

private struct CollabRow: View {
    let item: CollabItem
    let kind: CollabKind
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: stateIcon(item, kind: kind))
                    .font(.system(size: 14)).foregroundStyle(stateColor(item)).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text("#\(item.number)").monospacedDigit()
                        if !item.author.isEmpty { Text("· \(item.author)") }
                        if let updated = item.updated {
                            Text("· \(updated.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                        }
                        if item.comments > 0 {
                            Label("\(item.comments)", systemImage: "bubble.left").labelStyle(.titleAndIcon).font(.caption2)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !item.labels.isEmpty {
                        HStack(spacing: 4) { ForEach(item.labels.prefix(4), id: \.self) { LabelChip(name: $0) } }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowBackground(selected: selected, hovering: hovering)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Detail

struct CollabDetailView: View {
    @Bindable var store: RepositoryStore
    @Bindable var collab: CollabStore

    var body: some View {
        if let item = collab.selected {
            detail(item)
                .task(id: item.number) { collab.loadComments() }
                .alert("Couldn’t Complete", isPresented: Binding(get: { collab.actionError != nil }, set: { if !$0 { collab.actionError = nil } })) {
                    Button("OK", role: .cancel) {}
                } message: { Text(collab.actionError ?? "") }
        } else {
            ContentUnavailableView(collab.kind == .pullRequest ? "No \(store.pullRequestsTitle) Selected" : "No Issue Selected",
                                   systemImage: collab.kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle",
                                   description: Text("Select an item to read it here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func detail(_ item: CollabItem) -> some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title).font(.system(size: 20, weight: .semibold, design: .rounded)).textSelection(.enabled)

                    HStack(spacing: 10) {
                        Label(stateWord(item), systemImage: stateIcon(item, kind: collab.kind))
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .foregroundStyle(.white)
                            .background(stateColor(item), in: Capsule())
                        Text(summary(item)).font(.callout).foregroundStyle(.secondary)
                    }

                    if collab.kind == .pullRequest, !item.sourceBranch.isEmpty {
                        HStack(spacing: 6) {
                            branchChip(item.sourceBranch)
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                            branchChip(item.targetBranch)
                        }
                    }
                    if !item.labels.isEmpty {
                        HStack(spacing: 5) { ForEach(item.labels, id: \.self) { LabelChip(name: $0) } }
                    }

                    HStack(spacing: 8) {
                        if let url = item.url {
                            Button { NSWorkspace.shared.open(url) } label: {
                                Label("Open on \(store.providerTitle ?? "Web")", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.borderedProminent)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            } label: { Label("Copy Link", systemImage: "link") }
                            .buttonStyle(.bordered)
                        }
                        if collab.kind == .pullRequest, !item.sourceBranch.isEmpty,
                           let branch = store.remoteBranches.first(where: { $0.name.hasSuffix("/" + item.sourceBranch) }) {
                            Button { store.checkout(branch) } label: { Label("Check Out Branch", systemImage: "arrow.triangle.branch") }
                                .buttonStyle(.bordered)
                        }
                    }

                    if collab.canWrite { CollabActionBar(collab: collab, item: item) }

                    Divider()
                    if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description provided.").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(source: item.body)
                    }
                    if collab.canWrite { ConversationView(collab: collab) }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
    }

    private func branchChip(_ name: String) -> some View {
        Text(name).font(.system(.caption, design: .monospaced)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func summary(_ item: CollabItem) -> String {
        var parts = ["#\(item.number)"]
        if !item.author.isEmpty { parts.append("by \(item.author)") }
        if let created = item.created { parts.append(created.formatted(date: .abbreviated, time: .omitted)) }
        if item.comments > 0 { parts.append("\(item.comments) comment\(item.comments == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Actions and conversation

private struct CollabActionBar: View {
    @Bindable var collab: CollabStore
    let item: CollabItem

    var body: some View {
        HStack(spacing: 8) {
            if collab.kind == .pullRequest, item.state == .open {
                Menu {
                    ForEach(MergeMethod.allCases) { method in
                        Button(method.title) { confirmMerge(method) }
                    }
                } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                    .menuStyle(.borderedButton).fixedSize()
                    .disabled(item.isDraft)
                    .help(item.isDraft ? "Mark the draft as ready on the website before merging" : "Merge this pull request")
            }
            if item.state == .open {
                Button { collab.setOpen(false) } label: { Label("Close", systemImage: "xmark.circle") }.buttonStyle(.bordered)
            } else if item.state == .closed {
                Button { collab.setOpen(true) } label: { Label("Reopen", systemImage: "arrow.counterclockwise") }.buttonStyle(.bordered)
            }
            if !collab.repoLabels.isEmpty {
                Menu {
                    ForEach(collab.repoLabels, id: \.self) { label in
                        Button { toggle(label) } label: {
                            if item.labels.contains(label) { Label(label, systemImage: "checkmark") } else { Text(label) }
                        }
                    }
                } label: { Label("Labels", systemImage: "tag") }
                    .menuStyle(.borderedButton).fixedSize()
            }
            if collab.isWorking { ProgressView().controlSize(.small) }
        }
    }

    private func toggle(_ label: String) {
        var labels = item.labels
        if let i = labels.firstIndex(of: label) { labels.remove(at: i) } else { labels.append(label) }
        collab.setLabels(labels)
    }

    private func confirmMerge(_ method: MergeMethod) {
        let alert = NSAlert()
        alert.messageText = "\(method.title) #\(item.number)?"
        alert.informativeText = "“\(item.title)” will be merged into \(item.targetBranch). This can’t be undone from GitSync."
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { collab.merge(method) }
    }
}

private struct ConversationView: View {
    @Bindable var collab: CollabStore
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(collab.comments.isEmpty ? "Conversation" : "Conversation · \(collab.comments.count)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            if collab.isLoadingComments { ProgressView().controlSize(.small) }
            ForEach(collab.comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        AvatarView(name: comment.author, email: "", size: 22)
                        Text(comment.author).fontWeight(.semibold)
                        if let date = comment.created {
                            Text(date.formatted(.relative(presentation: .named))).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout)
                    MarkdownView(source: comment.body)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            TextField("Leave a comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...8)
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack {
                Spacer()
                Button("Comment") {
                    collab.addComment(draft.trimmingCharacters(in: .whitespacesAndNewlines))
                    draft = ""
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || collab.isWorking)
            }
        }
    }
}
