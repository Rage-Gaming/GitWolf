import AppKit
import GitWolfCore
import SwiftUI

/// Open pull requests across every open repository, split into "yours", "needs a look" and "CI failing".
@MainActor @Observable
final class PullRequestOverview {
    struct Entry: Identifiable {
        let id: String
        let repo: String
        let repoID: String
        let item: CollabItem
        let mine: Bool
        var checks: CheckState?
    }

    private(set) var entries: [Entry] = []
    private(set) var loading = false
    private(set) var skipped: [String] = []
    private(set) var signedOut = false

    func load(_ workspace: Workspace) async {
        loading = true
        defer { loading = false }
        var found: [Entry] = []
        var skippedNames: [String] = []
        var anonymous = false
        for store in workspace.repos where store.supports(.pullRequest) {
            guard let (client, path) = await store.providerClient() else { skippedNames.append(store.name); continue }
            let account = AccountStorage.account(forHost: store.remoteLocation?.host ?? "")
            if account == nil { anonymous = true }
            guard let items = try? await client.collab(.pullRequest, repoPath: path, filter: .open, page: 1) else {
                skippedNames.append(store.name); continue
            }
            let me = account?.username.lowercased() ?? ""
            for item in items {
                found.append(Entry(id: "\(store.id)#\(item.number)", repo: store.name, repoID: store.id, item: item,
                                   mine: !me.isEmpty && item.author.lowercased() == me))
            }
        }
        entries = found
        skipped = skippedNames
        signedOut = anonymous
        // CI for the first few, a lookup each, filling in as they arrive.
        for (index, entry) in found.prefix(30).enumerated() where !entry.item.headSHA.isEmpty && !entry.item.isDraft {
            guard let store = workspace.repos.first(where: { $0.id == entry.repoID }),
                  let (client, path) = await store.providerClient(),
                  let status = try? await client.ciStatus(repoPath: path, sha: entry.item.headSHA) else { continue }
            if entries.indices.contains(index), entries[index].id == entry.id { entries[index].checks = status.overall }
        }
    }
}

/// "My open PRs", "Others" and "CI failing" across all open repositories.
struct PullRequestOverviewSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var overview = PullRequestOverview()
    @State private var filter = Filter.mine

    enum Filter: String, CaseIterable, Identifiable {
        case mine = "Mine", others = "Others", failing = "CI failing"
        var id: String { rawValue }
    }

    private var shown: [PullRequestOverview.Entry] {
        switch filter {
        case .mine: overview.entries.filter(\.mine)
        case .others: overview.entries.filter { !$0.mine }
        case .failing: overview.entries.filter { $0.checks == .failure }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pull Requests").font(.system(size: 17, weight: .semibold, design: .rounded))
                if overview.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await overview.load(workspace) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh").disabled(overview.loading)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { f in
                    Text("\(f.rawValue) (\(count(f)))").tag(f)
                }
            }
            .pickerStyle(.segmented).labelsHidden()

            if overview.signedOut {
                Label("Sign in to a GitHub or GitLab account (Settings > Accounts) to see which pull requests are yours.", systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if shown.isEmpty {
                Text(overview.loading ? "Loading…" : emptyText).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ScrollView { LazyVStack(spacing: 2) { ForEach(shown) { row($0) } } }.frame(height: 360)
            }
            if !overview.skipped.isEmpty {
                Text("Couldn’t load: \(overview.skipped.joined(separator: ", ")).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 640)
        .task { await overview.load(workspace) }
    }

    private var emptyText: String {
        switch filter {
        case .mine: "You have no open pull requests in these repositories."
        case .others: "No other open pull requests."
        case .failing: "Nothing is failing."
        }
    }

    private func count(_ f: Filter) -> Int {
        switch f {
        case .mine: overview.entries.filter(\.mine).count
        case .others: overview.entries.filter { !$0.mine }.count
        case .failing: overview.entries.filter { $0.checks == .failure }.count
        }
    }

    private func row(_ e: PullRequestOverview.Entry) -> some View {
        Button {
            if let url = e.item.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(e.checks)).foregroundStyle(tint(e.checks)).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.item.title).lineLimit(1).truncationMode(.tail)
                    Text("\(e.repo) #\(e.item.number) · \(e.item.author)" + (e.item.isDraft ? " · Draft" : ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let updated = e.item.updated { Text(updated, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Show Repository") { workspace.select(e.repoID); workspace.sheet = nil }
        }
    }

    private func symbol(_ s: CheckState?) -> String {
        switch s {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        default: "circle.dashed"
        }
    }

    private func tint(_ s: CheckState?) -> Color {
        switch s {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        default: .secondary
        }
    }
}
