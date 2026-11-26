import GitSyncCore
import SwiftUI

struct RepositoryView: View {
    @Bindable var store: RepositoryStore

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 380)
        } content: {
            Group {
                switch store.mode {
                case .history: HistoryView(store: store)
                case .changes: ChangesView(store: store)
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 480, max: 760)
        } detail: {
            switch store.mode {
            case .history: CommitDetailView(store: store)
            case .changes: DiffPane(diff: store.diff, path: store.selectedTarget?.path)
            }
        }
        .navigationTitle(store.name)
        .navigationSubtitle(store.status.branchDisplay)
        .toolbar { toolbar }
        .task { store.start() }
        .overlay(alignment: .bottom) { if let label = store.busyLabel { BusyPill(label: label) } }
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
                PromptSheet(title: "New Tag", placeholder: "v1.0.0", confirm: "Create") { name, _ in
                    store.createTag(name, at: hash)
                }
            case .stash:
                PromptSheet(title: "Stash Changes", placeholder: "Message (optional)", confirm: "Stash", allowEmpty: true) { msg, _ in
                    store.stashPush(msg)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Menu {
                ForEach(store.localBranches) { branch in
                    Button {
                        store.checkout(branch)
                    } label: {
                        if branch.isCurrent { Label(branch.name, systemImage: "checkmark") } else { Text(branch.name) }
                    }
                }
                Divider()
                Button("New Branch…", systemImage: "plus") { store.sheet = .newBranch(from: nil) }
            } label: {
                Label(store.status.branchDisplay, systemImage: "arrow.triangle.branch")
            }
            .help("Switch branch")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.fetch() } label: { Label("Fetch", systemImage: "arrow.triangle.2.circlepath") }
                .help("Fetch from all remotes (⇧⌘F)")
            Button { store.pull() } label: {
                badged("Pull", "arrow.down", store.status.behind)
            }
            .help("Pull (⇧⌘L)")
            Button { store.push() } label: {
                badged("Push", "arrow.up", store.status.ahead)
            }
            .help("Push (⇧⌘P)")
            Button { store.sheet = .stash } label: { Label("Stash", systemImage: "tray.and.arrow.down") }
                .help("Stash changes")
                .disabled(store.status.isClean)
        }
    }

    private func badged(_ title: String, _ icon: String, _ count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            if count > 0 { Text("\(count)").font(.caption.monospacedDigit().weight(.semibold)) }
        }
        .accessibilityLabel(count > 0 ? "\(title), \(count)" : title)
    }
}

struct BusyPill: View {
    let label: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label).font(.callout)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
