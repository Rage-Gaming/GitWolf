import GitSyncCore
import SwiftUI

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Everywhere HEAD has been, newest first, so a lost commit can be found and brought back.
struct ReflogSheet: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [ReflogEntry] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reflog").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Every place HEAD has been. Resetting to an earlier entry brings back commits you dropped.")
                .font(.callout).foregroundStyle(.secondary)
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 200)
            } else if entries.isEmpty {
                Text("No reflog entries.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(entries) { row($0) } }
                }
                .frame(height: 360)
            }
        }
        .padding(22)
        .frame(width: 600)
        .task { entries = (try? await store.repo.reflog()) ?? []; loaded = true }
    }

    private func row(_ e: ReflogEntry) -> some View {
        HStack(spacing: 10) {
            Text(e.shortHash).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.message).lineLimit(1).truncationMode(.tail)
                Text(e.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if e.index == 0 { Text("Current").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
            else {
                Menu("Reset") {
                    Button("Soft: keep changes staged") { go { store.reset(to: e.hash, label: e.shortHash, mode: .soft) } }
                    Button("Mixed: keep changes unstaged") { go { store.reset(to: e.hash, label: e.shortHash, mode: .mixed) } }
                    Button("Hard: discard changes…") { go { store.reset(to: e.hash, label: e.shortHash, mode: .hard) } }
                    Divider()
                    Button("Checkout (detached)") { go { store.checkout(commit: e.hash) } }
                    Button("New Branch Here…") { go { store.sheet = .newBranch(from: e.hash) } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func go(_ action: @escaping @MainActor () -> Void) {
        dismiss()
        // Let the sheet close before a confirmation alert or another sheet appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { action() } }
    }
}
