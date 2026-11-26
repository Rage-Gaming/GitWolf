import GitSyncCore
import SwiftUI

private struct HistoryItem: Identifiable {
    let commit: Commit
    let graph: GraphRow?
    var id: String { commit.id }
}

private enum HistoryScope: String, CaseIterable, Identifiable {
    case loaded = "Message, author or hash"
    case message = "Message (all history)"
    case author = "Author (all history)"
    case contentChanged = "Code added or removed"
    case contentRegex = "Code matching regex"
    var id: String { rawValue }

    var kind: HistoryQuery.Kind? {
        switch self {
        case .loaded: nil
        case .message: .message
        case .author: .author
        case .contentChanged: .contentChanged
        case .contentRegex: .contentRegex
        }
    }

    var prompt: String {
        switch self {
        case .loaded: "Search commits"
        case .message: "Search commit messages"
        case .author: "Search by author"
        case .contentChanged: "Text added or removed in a diff"
        case .contentRegex: "Regex matched in a diff"
        }
    }
}

struct HistoryView: View {
    @Bindable var store: RepositoryStore
    @State private var query = ""
    @State private var scope = HistoryScope.loaded
    @State private var path = ""
    @State private var useSince = false
    @State private var useUntil = false
    @State private var since = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var until = Date()
    @State private var showFilters = false
    @State private var found: [Commit] = []
    @State private var searching = false
    @State private var searchError: String?

    private var hasFilters: Bool { scope != .loaded || !path.isEmpty || useSince || useUntil }
    /// Searching in git (instead of filtering the loaded commits) when a scope, file or date is set.
    private var gitSearch: Bool { scope != .loaded || !path.trimmingCharacters(in: .whitespaces).isEmpty || useSince || useUntil }

    private var gitQuery: HistoryQuery {
        HistoryQuery(kind: scope.kind ?? .message, text: query, path: path,
                     since: useSince ? since : nil, until: useUntil ? until : nil)
    }

    private var items: [HistoryItem] {
        if gitSearch { return found.map { HistoryItem(commit: $0, graph: nil) } }
        if query.isEmpty {
            return zip(store.commits, store.graph).map { HistoryItem(commit: $0, graph: $1) }
        }
        let q = query.lowercased()
        return store.commits
            .filter { $0.subject.lowercased().contains(q) || $0.authorName.lowercased().contains(q) || $0.hash.hasPrefix(q) }
            .map { HistoryItem(commit: $0, graph: nil) }
    }

    private var searchKey: String {
        "\(scope.rawValue)|\(query)|\(path)|\(useSince ? since.description : "")|\(useUntil ? until.description : "")"
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                SearchField(text: $query, prompt: scope.prompt)
                Button { showFilters.toggle() } label: {
                    Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 17)).foregroundStyle(hasFilters ? Theme.brand : .secondary)
                }
                .buttonStyle(.plain).help("Search options: scope, file and dates")
                .popover(isPresented: $showFilters, arrowEdge: .bottom) { filters }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            if gitSearch, let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red).padding(8)
            }
            list(items)
        }
        .task(id: searchKey) { await runSearch() }
        #if DEBUG
        .onAppear {
            // GITSYNC_HISTORY_SEARCH="<scope>|<text>|<path>" for snapshots.
            guard let v = ProcessInfo.processInfo.environment["GITSYNC_HISTORY_SEARCH"] else { return }
            let parts = v.components(separatedBy: "|")
            if let scope = HistoryScope.allCases.first(where: { $0.kind?.rawValue == parts[0] }) { self.scope = scope }
            if parts.count > 1 { query = parts[1] }
            if parts.count > 2 { path = parts[2] }
        }
        #endif
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search Options").font(.headline)
            Picker("Look in", selection: $scope) {
                ForEach(HistoryScope.allCases) { Text($0.rawValue).tag($0) }
            }
            if scope == .contentChanged || scope == .contentRegex {
                Text("Finds commits whose changes add or remove the text. Can take a moment on large repositories.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("Only commits touching this file or folder", text: $path).textFieldStyle(.roundedBorder)
            HStack {
                Toggle("From", isOn: $useSince)
                DatePicker("", selection: $since, displayedComponents: .date).labelsHidden().disabled(!useSince)
            }
            HStack {
                Toggle("To", isOn: $useUntil)
                DatePicker("", selection: $until, displayedComponents: .date).labelsHidden().disabled(!useUntil)
            }
            if hasFilters {
                Button("Reset") { scope = .loaded; path = ""; useSince = false; useUntil = false }
            }
        }
        .padding(16).frame(width: 340)
    }

    private func runSearch() async {
        guard gitSearch else { found = []; searchError = nil; searching = false; return }
        // A short pause so typing doesn't start a search per keystroke.
        try? await Task.sleep(for: .milliseconds(300))
        if Task.isCancelled { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty && scope != .loaded && path.isEmpty && !useSince && !useUntil { found = []; return }
        searching = true
        defer { searching = false }
        do {
            let result = try await store.repo.search(gitQuery, remotes: Set(store.remotes))
            if !Task.isCancelled { found = result; searchError = nil }
        } catch {
            if !Task.isCancelled { found = []; searchError = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func list(_ items: [HistoryItem]) -> some View {
        Group {
            if !store.isLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView((query.isEmpty && !gitSearch) ? "No Commits Yet" : (searching ? "Searching…" : "No Matches"),
                                       systemImage: "clock.arrow.circlepath",
                                       description: Text((query.isEmpty && !gitSearch) ? "Commit your changes to start the history." : "Try a different search."))
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
                            if store.canLoadMore && query.isEmpty && !gitSearch {
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
            Menu("Bisect") {
                if store.bisect.isActive {
                    Button("This Commit Is Good") { store.bisectMarkCommit(.good, hash: c.hash) }
                    Button("This Commit Is Bad") { store.bisectMarkCommit(.bad, hash: c.hash) }
                    Button("Skip This Commit") { store.bisectMarkCommit(.skip, hash: c.hash) }
                } else {
                    Button("Bisect: This Is Bad") { store.bisectMarkCommit(.bad, hash: c.hash) }
                    Button("Bisect: This Is Good") { store.bisectMarkCommit(.good, hash: c.hash) }
                }
            }
            Button("Export as Patch…") { store.exportPatch(of: [c.hash]) }
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
