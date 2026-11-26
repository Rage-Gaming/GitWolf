import GitSyncCore
import SwiftUI

struct ChangesView: View {
    @Bindable var store: RepositoryStore

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
            ZStack(alignment: .topLeading) {
                TextEditor(text: $store.draftMessage)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if store.draftMessage.isEmpty {
                    Text("Describe your changes…").foregroundStyle(.tertiary)
                        .padding(.horizontal, 13).padding(.vertical, 16).allowsHitTesting(false)
                }
            }
            .frame(height: 96)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))

            HStack {
                Toggle("Amend last commit", isOn: $store.amend).toggleStyle(.checkbox).controlSize(.small)
                let subject = store.draftMessage.split(separator: "\n").first.map(String.init) ?? ""
                if subject.count > 72 {
                    Text("\(subject.count)").font(.caption.monospacedDigit()).foregroundStyle(.orange)
                        .help("Subject line is longer than 72 characters")
                }
                Spacer()
                Button { store.commit() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                        Text(store.amend ? "Amend" : "Commit")
                        if !store.amend { Text("\(store.status.staged.count)").opacity(0.75) }
                    }
                    .fontWeight(.semibold).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(canCommit ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Color.primary.opacity(0.15)), in: Capsule())
                    .shadow(color: canCommit ? Theme.brand.opacity(0.35) : .clear, radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canCommit)
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
            if source == .staged {
                Button("Unstage") { store.unstage([change.path]) }
            } else {
                Button("Stage") { store.stage([change.path]) }
                Button("Discard Changes…", role: .destructive) { confirmDiscard(untracked: source == .untracked) }
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([store.repo.root.appendingPathComponent(change.path)])
            }
        }
    }

    private func confirmDiscard(untracked: Bool) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to “\(change.fileName)”?"
        alert.informativeText = untracked ? "This untracked file will be deleted. This can’t be undone."
                                          : "Your modifications will be lost. This can’t be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { store.discard([change], untracked: untracked) }
    }
}
