import GitSyncCore
import SwiftUI

/// ⌘K: jump between repositories and branches, or run common actions.
struct CommandPalette: View {
    let workspace: Workspace
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let run: () -> Void
    }

    private var items: [Item] {
        var all: [Item] = workspace.repos.map { store in
            Item(id: "repo-\(store.id)", title: store.name, subtitle: "Switch repository", icon: "folder.fill") {
                workspace.select(store.id)
            }
        }
        if let s = workspace.selected {
            all += [
                Item(id: "fetch", title: "Fetch", subtitle: "Repository action", icon: "arrow.triangle.2.circlepath") { s.fetch() },
                Item(id: "pull", title: "Pull", subtitle: "Repository action", icon: "arrow.down") { s.pull() },
                Item(id: "push", title: "Push", subtitle: "Repository action", icon: "arrow.up") { s.push() },
                Item(id: "newbranch", title: "New Branch…", subtitle: "Repository action", icon: "plus") { s.sheet = .newBranch(from: nil) },
                Item(id: "history", title: "Show History", subtitle: "View", icon: "clock.arrow.circlepath") { s.mode = .history },
                Item(id: "changes", title: "Show Changes", subtitle: "View", icon: "square.and.pencil") { s.mode = .changes },
            ]
            all.append(Item(id: "undo", title: "Undo Last Change…", subtitle: "Repository action", icon: "arrow.uturn.backward") { s.undoLastChange() })
            all.append(Item(id: "compare", title: "Compare Refs…", subtitle: "Repository action", icon: "arrow.left.arrow.right") { s.openCompare() })
            if s.providerTitle != nil {
                all.append(Item(id: "new-pr", title: "New \(s.webLinks?.pullRequestsWord ?? "Pull Request")…", subtitle: "Hosting", icon: "arrow.triangle.pull") { s.sheet = .newCollab(.pullRequest) })
                all.append(Item(id: "new-issue", title: "New Issue…", subtitle: "Hosting", icon: "smallcircle.filled.circle") { s.sheet = .newCollab(.issue) })
            }
            if s.canFork { all.append(Item(id: "fork", title: "Fork on \(s.providerTitle ?? "provider")…", subtitle: "Hosting", icon: "arrow.triangle.branch") { s.sheet = .fork }) }
            all.append(Item(id: "notifications", title: "Notifications…", subtitle: "Hosting", icon: "bell") { s.sheet = .notifications })
            all.append(Item(id: "cleanup", title: "Clean Up Branches…", subtitle: "Repository action", icon: "trash.slash") { s.sheet = .cleanup })
            all.append(Item(id: "reflog", title: "Open Reflog…", subtitle: "Repository action", icon: "clock.arrow.circlepath") { s.sheet = .reflog })
            if let op = s.operation {
                all.append(Item(id: "op-continue", title: "Continue \(op.verb)", subtitle: "Repository action", icon: "play.fill") { s.continueOperation() })
                if op.canSkip { all.append(Item(id: "op-skip", title: "Skip Current Commit", subtitle: "Repository action", icon: "forward.fill") { s.skipOperation() }) }
                all.append(Item(id: "op-abort", title: "Abort \(op.verb)", subtitle: "Repository action", icon: "xmark.octagon") { s.abortOperation() })
            }
            if s.supports(.pullRequest) {
                all.append(Item(id: "show-prs", title: "Show \(s.pullRequestsTitle)", subtitle: "View", icon: "arrow.triangle.pull") { s.mode = .pullRequests })
            }
            if s.supports(.issue) {
                all.append(Item(id: "show-issues", title: "Show Issues", subtitle: "View", icon: "smallcircle.filled.circle") { s.mode = .issues })
            }
            if s.webLinks != nil {
                let site = s.providerTitle ?? "Web"
                all += [
                    Item(id: "web-repo", title: "Open on \(site)", subtitle: "Repository action", icon: "arrow.up.right.square") { s.openOnWeb(.repository) },
                    Item(id: "web-branch", title: "Open Branch on \(site)", subtitle: "Repository action", icon: "arrow.triangle.branch") { s.openOnWeb(.branch) },
                    Item(id: "web-pr", title: "Create \(s.webLinks?.pullRequestsWord ?? "Pull Request") on \(site)", subtitle: "Repository action", icon: "arrow.triangle.pull") { s.openOnWeb(.pullRequest) },
                ]
            }
            all += s.localBranches.filter { !$0.isCurrent }.map { b in
                Item(id: "branch-\(b.id)", title: b.name, subtitle: "Checkout branch", icon: "arrow.triangle.branch") { s.checkout(b) }
            }
        }
        all.append(Item(id: "open", title: "Open Repository…", subtitle: "Workspace", icon: "folder.badge.plus") { workspace.openPanel() })
        all.append(Item(id: "clone", title: "Clone Repository…", subtitle: "Workspace", icon: "square.and.arrow.down") { workspace.sheet = .clone })
        all.append(Item(id: "create", title: "New Repository…", subtitle: "Workspace", icon: "plus.rectangle.on.folder") { workspace.sheet = .create })
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? all : all.filter { ($0.title + " " + $0.subtitle).lowercased().contains(q) }
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: close)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(.secondary)
                    TextField("Jump to a repository, branch or action…", text: $query)
                        .textFieldStyle(.plain).font(.title3)
                        .focused($focused)
                        .onSubmit { run(items) }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                    Kbd(text: "esc")
                }
                .padding(16)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 12) {
                                    Image(systemName: item.icon).frame(width: 22).foregroundStyle(i == index ? Theme.brand : .secondary)
                                    Text(item.title).fontWeight(.medium)
                                    Spacer()
                                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).frame(height: 38)
                                .rowBackground(selected: i == index, hovering: false)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; run(items) }
                                .id(item.id)
                            }
                            if items.isEmpty {
                                Text("No results").foregroundStyle(.secondary).padding(24)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: index) { _, new in
                        if items.indices.contains(new) { proxy.scrollTo(items[new].id) }
                    }
                }
                .frame(maxHeight: 360)
            }
            .frame(width: 580)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
            .padding(.top, 110)
        }
        .onChange(of: query) { _, _ in index = 0 }
        .onAppear { focused = true }
        .transition(.opacity)
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(index) else { return }
        let item = items[index]
        close()
        item.run()
    }

    private func close() { workspace.showPalette = false }
}
