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

                    Divider()
                    if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("No description provided.").foregroundStyle(.secondary)
                    } else {
                        Text(rendered(item.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(collab.kind == .pullRequest ? "No \(store.pullRequestsTitle) Selected" : "No Issue Selected",
                                   systemImage: collab.kind == .pullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle",
                                   description: Text("Select an item to read it here."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
