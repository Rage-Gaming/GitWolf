import GitSyncCore
import SwiftUI

struct RepositoryView: View {
    @Bindable var store: RepositoryStore
    let workspace: Workspace
    @AppStorage("sidebarWidth") private var sidebarWidth = 248.0
    @AppStorage("contentWidth") private var contentWidth = 480.0

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, workspace: workspace)
            if let operation = store.operation {
                OperationBanner(store: store, operation: operation)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if store.bisect.isActive || store.bisectBad != nil || store.bisectGood != nil {
                BisectBanner(store: store)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if store.isShallow {
                ShallowBanner(store: store)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            }
            GeometryReader { geo in
                let sidebar = CGFloat(sidebarWidth)
                let content = min(CGFloat(contentWidth), max(320, geo.size.width - sidebar - 380 - 24))
                HStack(spacing: 0) {
                    SidebarView(store: store).frame(width: sidebar)
                    SplitHandle(width: $sidebarWidth, range: 180...480)
                    mainColumn.frame(width: content).panel()
                    SplitHandle(width: $contentWidth, range: 280...900)
                    detailColumn.frame(minWidth: 360, maxWidth: .infinity).panel()
                }
                .padding(.trailing, 10).padding(.bottom, 10)
            }
        }
        .environment(\.lfsPaths, store.lfsPaths)
        .environment(store.avatars)
        .animation(.snappy, value: store.bisect.isActive)
        .task { store.start(); NotificationsStore.shared.startPolling() }
        .overlay(alignment: .bottom) {
            if let label = store.busyLabel { BusyPill(label: label) }
            else if let branch = store.pushOffer { PushOfferBanner(store: store, branch: branch).padding(.bottom, 18).transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .animation(.snappy, value: store.busyLabel)
        .animation(.snappy, value: store.operation)
        .alert("Git Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .newBranch(let from):
                PromptSheet(title: "New Branch", placeholder: "branch-name", confirm: "Create",
                            toggleTitle: "Switch to the new branch") { name, checkout in
                    store.createBranch(name, from: from, checkout: checkout)
                }
            case .newTag(let hash):
                NewTagSheet(store: store, hash: hash)
            case .rebase(let plan):
                RebaseSheet(store: store, plan: plan)
            case .stashHunk(let index):
                PromptSheet(title: "Stash Hunk", placeholder: "Message (optional)", confirm: "Stash", allowEmpty: true) { msg, _ in
                    store.stashHunk(index, message: msg)
                }
            case .fileHistory(let path):
                FileHistorySheet(store: store, path: path)
            case .renameBranch(let name):
                PromptSheet(title: "Rename Branch", placeholder: "new-name", confirm: "Rename", initial: name) { new, _ in
                    store.renameBranch(name, to: new)
                }
            case .hookFailure(let failure):
                HookOutputSheet(failure: failure) { store.commit(skipHooks: true) }
            case .newCollab(let kind):
                NewCollabSheet(store: store, kind: kind)
            case .notifications:
                NotificationsSheet()
            case .fork:
                ForkSheet(store: store)
            case .remotes:
                RemotesSheet(store: store)
            case .worktrees:
                WorktreesSheet(store: store, workspace: workspace)
            case .cleanup:
                BranchCleanupSheet(store: store)
            case .reflog:
                ReflogSheet(store: store)
            case .stash:
                PromptSheet(title: "Stash Changes", placeholder: "Message (optional)", confirm: "Stash", allowEmpty: true) { msg, _ in
                    store.stashPush(msg)
                }
            }
        }
    }

    @ViewBuilder private var mainColumn: some View {
        switch store.mode {
        case .history: HistoryView(store: store)
        case .stash: StashView(store: store)
        case .compare: CompareView(store: store)
        case .changes: ChangesView(store: store)
        case .pullRequests: CollabListView(store: store, collab: store.pullRequests)
        case .issues: CollabListView(store: store, collab: store.issues)
        }
    }

    private var stashHunk: (@MainActor (Int) -> Void)? {
        guard store.canStashHunk else { return nil }
        return { store.sheet = .stashHunk($0) }
    }

    private var staging: DiffStaging? {
        guard store.canPatch, let target = store.selectedTarget else { return nil }
        return DiffStaging(
            staged: target.source == .staged,
            selection: store.lineSelection,
            toggle: { store.toggleLine($0, extend: $1) },
            clear: { store.clearLineSelection() },
            hunk: { store.applyHunk($0, action: $1) },
            lines: { store.applySelectedLines(action: $0) },
            hunkSummary: { store.hunkSummary($0) },
            lineSummary: { store.changeSummary(store.lineSelection) },
            stashHunk: stashHunk)
    }

    @ViewBuilder private var detailColumn: some View {
        switch store.mode {
        case .history: CommitDetailView(store: store)
        case .stash, .compare: DiffPane(diff: store.diff, path: store.selectedTarget?.path, reload: { store.reloadDiff() }, images: { await store.imageVersions() })
        case .changes:
            if let t = store.selectedTarget, t.source == .conflicted, store.status.conflicted.contains(where: { $0.path == t.path }) {
                ConflictResolverView(store: store, path: t.path).id(t.path)
            } else {
                DiffPane(diff: store.diff, path: store.selectedTarget?.path, staging: staging, reload: { store.reloadDiff() }, images: { await store.imageVersions() })
            }
        case .pullRequests: CollabDetailView(store: store, collab: store.pullRequests)
        case .issues: CollabDetailView(store: store, collab: store.issues)
        }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Bindable var store: RepositoryStore
    let workspace: Workspace
    @Namespace private var tabs

    var body: some View {
        HStack(spacing: 14) {
            branchMenu
            modeTabs
            Spacer(minLength: 12)
            syncCluster
            openInMenu
            if NotificationsStore.shared.hasAccounts { bell }
            Button { workspace.showPalette = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                    Text("Jump to…").foregroundStyle(.secondary)
                    Kbd(text: "⌘K")
                }
                .toolbarControl()
            }
            .buttonStyle(.plain)
            .help("Jump to a repository, branch or action")
        }
        .padding(.horizontal, 10)
        .frame(height: 56)
        .background { Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()) }
    }

    static func symbol(for branch: String) -> String {
        if case .symbol(let name) = FileIcons.branchIcon(named: branch).glyph { return name }
        return "arrow.triangle.branch"
    }

    /// The current branch's icon and colour (the plain brand branch symbol when detached or unborn).
    private var currentIcon: (symbol: String, color: Color) {
        guard let name = store.status.branch else { return ("arrow.triangle.branch", Theme.brand) }
        return (Self.symbol(for: name), Color(hex: FileIcons.branchIcon(named: name).color))
    }

    private var branchMenu: some View {
        Menu {
            ForEach(store.localBranches) { branch in
                Button {
                    store.checkout(branch)
                } label: {
                    if branch.isCurrent { Label(branch.name, systemImage: "checkmark") }
                    else { Label(branch.name, systemImage: Self.symbol(for: branch.name)) }
                }
            }
            Divider()
            Button("New Branch…", systemImage: "plus") { store.sheet = .newBranch(from: nil) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: currentIcon.symbol).foregroundStyle(currentIcon.color)
                Text(store.status.branchDisplay).fontWeight(.semibold).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            }
            .toolbarControl()
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("Switch branch")
    }

    private var openInMenu: some View {
        Menu {
            Button("Show in Finder", systemImage: "folder") { store.openInFinder() }
            Button("Open in Terminal", systemImage: "terminal") { store.openInTerminal() }
            Button("Open in \(CustomActionStore.editorApp)", systemImage: "chevron.left.forwardslash.chevron.right") { store.openInEditor() }
            let actions = CustomActionStore.load().filter(\.isValid)
            if !actions.isEmpty {
                Divider()
                ForEach(actions) { action in Button(action.name, systemImage: "play") { store.run(action) } }
            }
        } label: {
            Image(systemName: "square.and.arrow.up.on.square").toolbarControl(square: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .help("Open the repository in Finder, Terminal or your editor, or run a custom action")
        .accessibilityLabel("Open repository in")
    }

    private var modeTabs: some View {
        HStack(spacing: 2) {
            tab("History", "clock.arrow.circlepath", .history, badge: nil)
            tab("Changes", "square.and.pencil", .changes, badge: store.status.changeCount)
            if store.supports(.pullRequest) {
                tab(store.webLinks?.pullRequestsWord == "Merge Request" ? "Merges" : "Pulls", "arrow.triangle.pull", .pullRequests, badge: nil)
            }
            if store.supports(.issue) { tab("Issues", "smallcircle.filled.circle", .issues, badge: nil) }
        }
        .padding(3)
        .frame(height: Theme.barControlHeight)
        .barSurface()
    }

    private func tab(_ title: String, _ icon: String, _ mode: RepositoryStore.Mode, badge: Int?) -> some View {
        let selected = store.mode == mode
        return Button {
            withAnimation(.snappy(duration: 0.22)) { store.mode = mode }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title).fontWeight(.medium)
                if let badge, badge > 0 {
                    Text("\(badge)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, 13).frame(maxHeight: .infinity)
            .background {
                if selected {
                    Capsule().fill(Color(nsColor: .textBackgroundColor))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                        .matchedGeometryEffect(id: "selected-tab", in: tabs)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bell: some View {
        let count = NotificationsStore.shared.unreadCount
        return Button { store.sheet = .notifications } label: {
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
                .symbolRenderingMode(count > 0 ? .multicolor : .monochrome)
                .toolbarControl(square: true)
        }
        .buttonStyle(.plain)
        .help(count > 0 ? "\(count) notification\(count == 1 ? "" : "s")" : "Notifications")
    }

    private var syncCluster: some View {
        HStack(spacing: 0) {
            SyncButton(icon: "arrow.triangle.2.circlepath", motion: store.busyLabel?.hasPrefix("Fetching") == true ? .spin : nil, count: 0, help: "Fetch (⇧⌘F)") { store.fetch() }
            Divider().frame(height: 16)
            SyncButton(icon: "arrow.down", motion: store.busyLabel?.hasPrefix("Pulling") == true ? .down : nil, count: store.status.behind, help: "Pull (⇧⌘L). Right-click for more") { store.pull() }
                .contextMenu {
                    ForEach(PullStrategy.allCases, id: \.self) { strategy in
                        Button(strategy.title) { store.pull(strategy: strategy) }
                    }
                }
            Divider().frame(height: 16)
            SyncButton(icon: "arrow.up", motion: store.busyLabel?.hasSuffix("ushing…") == true || store.busyLabel?.hasPrefix("Pushing") == true ? .up : nil, count: store.status.ahead, help: "Push (⇧⌘P). Right-click for more") { store.push() }
                .contextMenu {
                    Button("Push") { store.push() }
                    Button("Push with Tags") { store.push(options: PushOptions(includeTags: true)) }
                    Button("Force Push (with Lease)…") { store.confirmForcePush() }
                    if store.remotes.count > 1 {
                        Divider()
                        ForEach(store.remotes, id: \.self) { remote in
                            Button("Push to \(remote)") { store.push(options: PushOptions(remote: remote)) }
                        }
                    }
                    Divider()
                    Button("Manage Remotes…") { store.sheet = .remotes }
                }
            Divider().frame(height: 16)
            SyncButton(icon: "tray.and.arrow.down", count: 0, help: "Stash changes") { store.sheet = .stash }
                .disabled(store.status.isClean)
        }
        .frame(height: Theme.barControlHeight)
        .clipShape(Capsule())
        .barSurface()
    }
}

/// How a sync icon moves while its operation runs.
private enum SyncMotion { case spin, down, up }

/// The sync icon; it animates while its operation is running and sits still otherwise.
private struct SyncIcon: View {
    let name: String
    let motion: SyncMotion?

    var body: some View {
        // A timeline only while running, so an idle toolbar costs nothing.
        TimelineView(.animation(paused: motion == nil)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let image = Image(systemName: name).font(.system(size: 13, weight: .semibold))
            switch motion {
            case .spin:
                image.rotationEffect(.degrees((t * 360 / 1.1).truncatingRemainder(dividingBy: 360)))
            case .down, .up:
                // The arrow slides out of the button in its direction and fades back in from the other side.
                let phase = (t / 0.9).truncatingRemainder(dividingBy: 1)
                let travel: Double = 9
                let offset = (phase < 0.5 ? phase * 2 : phase * 2 - 2) * travel * (motion == .down ? 1 : -1)
                image.offset(y: offset).opacity(1 - abs(offset) / travel * 0.85)
            case nil:
                image
            }
        }
        .frame(width: 16, height: 16).clipped()
    }
}

private struct SyncButton: View {
    let icon: String
    var motion: SyncMotion?
    let count: Int
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            // The icon stays centred; the count is a badge on its corner, so it never pushes the icon aside.
            SyncIcon(name: icon, motion: motion)
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        Text("\(count)").font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 14, minHeight: 14)
                            .background(Theme.brand, in: Capsule())
                            .offset(x: 10, y: -7)
                    }
                }
                .frame(width: 44)
                .frame(maxHeight: .infinity)
            .background(hovering && enabled ? Color.primary.opacity(0.07) : .clear)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
        .accessibilityValue(count > 0 ? "\(count)" : "")
        .onHover { hovering = $0 }
    }
}


/// Shown after pushing a branch that has no pull request: one click opens the new pull request form.
struct PushOfferBanner: View {
    let store: RepositoryStore
    let branch: String

    var body: some View {
        let word = store.webLinks?.pullRequestsWord ?? "Pull Request"
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.pull").foregroundStyle(Theme.brand)
            Text("Pushed ").foregroundStyle(.secondary) + Text(branch).font(.system(.callout, design: .monospaced).weight(.medium))
            Button("Open \(word)") { store.pushOffer = nil; store.sheet = .newCollab(.pullRequest) }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Button { withAnimation(.snappy) { store.pushOffer = nil } } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss").accessibilityLabel("Dismiss")
        }
        .font(.callout)
        .padding(.leading, 16).padding(.trailing, 12).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.14)))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .task(id: branch) {
            try? await Task.sleep(for: .seconds(30))
            if store.pushOffer == branch { withAnimation(.snappy) { store.pushOffer = nil } }
        }
        .onChange(of: store.status.branch) { store.pushOffer = nil }
    }
}
