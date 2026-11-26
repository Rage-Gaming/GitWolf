import GitSyncCore
import SwiftUI

struct ChangesView: View {
    @Bindable var store: RepositoryStore
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if store.status.isClean {
                ContentUnavailableView("Working Tree Clean", systemImage: "checkmark.seal",
                                       description: Text("Nothing to commit. You’re all caught up."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if !store.status.conflicted.isEmpty {
                            group("Conflicts", store.status.conflicted.map { ($0, .conflicted) }, action: nil)
                        }
                        if !store.status.staged.isEmpty {
                            group("Staged", store.status.staged.map { ($0, .staged) }, action: ("Unstage All", store.unstageAll))
                        }
                        let rest = store.status.unstaged.map { ($0, DiffTarget.Source.unstaged) }
                            + store.status.untracked.map { ($0, DiffTarget.Source.untracked) }
                        if !rest.isEmpty {
                            group("Changes", rest, action: ("Stage All", store.stageAll))
                        }
                    }
                    .padding(10)
                }
            }
            Divider()
            composer
        }
    }

    private func group(_ title: String, _ items: [(FileChange, DiffTarget.Source)],
                       action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.7)
                Text("\(items.count)").font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5).background(Color.primary.opacity(0.07), in: Capsule())
                Spacer()
                if let action {
                    Button(action.0, action: action.1).buttonStyle(.plain)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.brand)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(items, id: \.0.id) { change, source in
                ChangeRow(store: store, change: change, source: source)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A vertical TextField draws its own placeholder, so the caret and placeholder always align.
            TextField("Describe your changes…", text: $store.draftMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(4...5)
                .focused($composerFocused)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(height: 96)
            .contentShape(Rectangle())
            .onTapGesture { composerFocused = true }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))

            HStack {
                Toggle("Amend last commit", isOn: $store.amend).toggleStyle(.checkbox).controlSize(.small)
                if let signing = store.signing, signing.isConfigured {
                    Toggle(isOn: $store.signCommit) {
                        Label("Sign", systemImage: "signature")
                    }
                    .toggleStyle(.checkbox).controlSize(.small)
                    .help("Sign this commit with your \(signing.format.rawValue) key")
                }
                let subject = store.draftMessage.split(separator: "\n").first.map(String.init) ?? ""
                if subject.count > 72 {
                    Text("\(subject.count)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        .help("Subject line is longer than 72 characters")
                }
                Spacer()
                if !store.amend, !store.status.staged.isEmpty {
                    Text("\(store.status.staged.count) staged").font(.caption).foregroundStyle(.secondary)
                }
                Button { store.commit() } label: {
                    Text(store.amend ? "Amend" : "Commit")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(canCommit ? Color.white : Color.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(canCommit ? Theme.brand : Color.primary.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(canCommit ? Color.clear : Color.primary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
                .help(canCommit ? "Commit staged changes (⌘↩)" : "Stage files and write a message to commit")
            }
        }
        .padding(12)
    }

    private var canCommit: Bool {
        if store.isBusy { return false }
        if store.amend { return true }
        return !store.status.staged.isEmpty
            && !store.draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct ChangeRow: View {
    let store: RepositoryStore
    let change: FileChange
    let source: DiffTarget.Source
    @State private var hovering = false

    private var selected: Bool {
        store.selectedTarget?.path == change.path && store.selectedTarget?.source == source
    }

    var body: some View {
        HStack(spacing: 6) {
            FileRow(change: change)
            if hovering || selected, source != .conflicted {
                Button {
                    if source == .staged { store.unstage([change.path]) } else { store.stage([change.path]) }
                } label: {
                    Image(systemName: source == .staged ? "minus.circle.fill" : "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(source == .staged ? Color.secondary : Theme.brand)
                }
                .buttonStyle(.plain)
                .help(source == .staged ? "Unstage" : "Stage")
            }
        }
        .padding(.horizontal, 8).frame(height: 34)
        .rowBackground(selected: selected, hovering: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.selectChange(change, source: source) }
        .contextMenu {
            if source == .conflicted {
                Button("Resolve Using Ours") { store.resolveConflict(change.path, taking: .ours) }
                Button("Resolve Using Theirs") { store.resolveConflict(change.path, taking: .theirs) }
            } else if source == .staged {
                Button("Unstage") { store.unstage([change.path]) }
            } else {
                Button("Stage") { store.stage([change.path]) }
                Button("Discard Changes…", role: .destructive) { store.confirmDiscard([change], untracked: source == .untracked) }
            }
            if source != .untracked {
                Button("History & Blame…") { store.sheet = .fileHistory(change.path) }
            }
            Menu("Ignore") {
                ForEach(IgnoreRules.options(for: change.path)) { option in
                    Button(option.title) { store.ignore(option, local: false, untrack: source == .untracked ? nil : change.path) }
                }
                Divider()
                Menu("Only on This Machine") {
                    ForEach(IgnoreRules.options(for: change.path)) { option in
                        Button(option.title) { store.ignore(option, local: true, untrack: source == .untracked ? nil : change.path) }
                    }
                }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.repo.root.appendingPathComponent(change.path)])
            }
        }
    }
}
