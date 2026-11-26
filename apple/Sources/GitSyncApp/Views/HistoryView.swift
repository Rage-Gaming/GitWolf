import GitSyncCore
import SwiftUI

private struct HistoryItem: Identifiable {
    let commit: Commit
    let graph: GraphRow?
    var id: String { commit.id }
}

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var query = ""

    private var items: [HistoryItem] {
        if query.isEmpty {
            return zip(store.commits, store.graph).map { HistoryItem(commit: $0, graph: $1) }
        }
        let q = query.lowercased()
        return store.commits
            .filter { $0.subject.lowercased().contains(q) || $0.authorName.lowercased().contains(q) || $0.hash.hasPrefix(q) }
            .map { HistoryItem(commit: $0, graph: nil) }
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search commits")
                .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            list(items)
        }
    }

    @ViewBuilder
    private func list(_ items: [HistoryItem]) -> some View {
        Group {
            if !store.isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No Commits Yet" : "No Matches",
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text(query.isEmpty ? "Commit your changes to start the history." : "Try a different search."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                CommitRow(item: item, laneCount: store.graphLaneCount,
                                          selected: item.id == store.selectedCommitID, store: store)
                                    .id(item.id)
                                    .onTapGesture { store.selectCommit(item.id) }
                            }
                            if store.canLoadMore && query.isEmpty {
                                Button("Load More…") { store.loadMoreCommits() }
                                    .buttonStyle(.link).padding(12)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.downArrow) { move(1, items); return .handled }
                    .onKeyPress(.upArrow) { move(-1, items); return .handled }
                    .onChange(of: store.selectedCommitID) { _, id in
                        if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                    }
                }
            }
        }
    }

    private func move(_ delta: Int, _ items: [HistoryItem]) {
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == store.selectedCommitID } ?? (delta > 0 ? -1 : items.count)
        let next = min(max(current + delta, 0), items.count - 1)
        store.selectCommit(items[next].id)
    }
}

private struct CommitRow: View {
    let item: HistoryItem
    let laneCount: Int
    let selected: Bool
    let store: RepositoryStore
    @State private var hovering = false

    var body: some View {
        let c = item.commit
        HStack(spacing: 8) {
            if let graph = item.graph {
                GraphCell(row: graph, laneCount: laneCount)
            }
            AvatarView(name: c.authorName, email: c.authorEmail, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    ForEach(c.refs.prefix(3), id: \.self) { RefChip(label: $0) }
                    Text(c.subject).fontWeight(.medium).lineLimit(1)
                }
                Text("\(c.authorName) · \(c.shortHash)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(c.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(c.date.formatted(date: .complete, time: .shortened))
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.historyRowHeight)
        .rowBackground(selected: selected, hovering: hovering, radius: 12)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Checkout Commit") { store.checkout(commit: c.hash) }
            Button("New Branch Here…") { store.sheet = .newBranch(from: c.hash) }
            Button("New Tag…") { store.sheet = .newTag(hash: c.hash) }
            Divider()
            Button("Cherry-Pick") { store.cherryPick(c.hash) }
            Button("Revert") { store.revert(c.hash) }
            Button("Compare with Current Branch") { store.openCompare(from: c.hash, to: store.status.branch ?? "HEAD") }
            Button("Interactive Rebase from Here…") { store.beginInteractiveRebase(from: c.hash) }
            Menu("Reset Branch to Here") {
                Button("Soft: keep changes staged") { store.reset(to: c.hash, label: c.shortHash, mode: .soft) }
                Button("Mixed: keep changes unstaged") { store.reset(to: c.hash, label: c.shortHash, mode: .mixed) }
                Button("Hard: discard changes…") { store.reset(to: c.hash, label: c.shortHash, mode: .hard) }
            }
            Divider()
            if store.webLinks != nil {
                Button("Open on \(store.providerTitle ?? "Web")") { store.openOnWeb(.commit(c.hash)) }
            }
            Button("Copy Hash") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(c.hash, forType: .string)
            }
        }
    }
}

struct GraphCell: View {
    let row: GraphRow
    let laneCount: Int

    var body: some View {
        Canvas { ctx, size in
            let w = Theme.laneWidth
            let maxLane = laneCount - 1
            func x(_ lane: Int) -> CGFloat { CGFloat(min(lane, maxLane)) * w + w / 2 }
            let mid = size.height / 2

            func stroke(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, lane: Int) {
                var p = Path()
                p.move(to: CGPoint(x: x1, y: y1))
                if x1 == x2 {
                    p.addLine(to: CGPoint(x: x2, y: y2))
                } else {
                    let cy = (y1 + y2) / 2
                    p.addCurve(to: CGPoint(x: x2, y: y2), control1: CGPoint(x: x1, y: cy), control2: CGPoint(x: x2, y: cy))
                }
                ctx.stroke(p, with: .color(Theme.lane(lane)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            for e in row.top { stroke(x(e.from), 0, x(e.to), mid, lane: e.from) }
            for e in row.bottom { stroke(x(e.from), mid, x(e.to), size.height, lane: e.to) }

            let center = CGPoint(x: x(row.lane), y: mid)
            let dot = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            ctx.fill(Path(ellipseIn: dot.insetBy(dx: -2, dy: -2)), with: .color(Color(nsColor: .textBackgroundColor)))
            ctx.fill(Path(ellipseIn: dot), with: .color(Theme.lane(row.lane)))
        }
        .frame(width: CGFloat(laneCount) * Theme.laneWidth, height: Theme.historyRowHeight)
    }
}
