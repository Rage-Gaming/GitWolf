import GitWolfCore
import SwiftUI

/// Finds local branches that are merged or whose remote branch is gone, and deletes the ones you tick.
struct BranchCleanupSheet: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var items: [BranchCleanupItem] = []
    @State private var chosen: Set<String> = []
    @State private var loaded = false

    private var base: String { store.status.branch ?? "HEAD" }
    private var selectedItems: [BranchCleanupItem] { items.filter { chosen.contains($0.id) } }
    private var unmerged: [BranchCleanupItem] { selectedItems.filter { !$0.isMerged } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clean Up Branches").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Local branches already merged into \(base), or whose branch on the remote was deleted. The current branch and main, master, develop are never listed.")
                .font(.callout).foregroundStyle(.secondary)
            if !loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
            } else if items.isEmpty {
                Label("Nothing to clean up.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(items) { row($0) } }
                }
                .frame(height: min(320, CGFloat(items.count) * 44 + 8))
                if !unmerged.isEmpty {
                    Label("\(unmerged.count) selected branch\(unmerged.count == 1 ? " has" : "es have") commits that aren’t merged anywhere. Deleting loses them (recoverable only from the reflog).",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            HStack {
                if !items.isEmpty {
                    Button("Select Merged") { chosen = Set(items.filter(\.isMerged).map(\.id)) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Delete \(chosen.count) Branch\(chosen.count == 1 ? "" : "es")") {
                    store.deleteBranches(selectedItems)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            items = (try? await store.repo.cleanupCandidates(base: base)) ?? []
            chosen = Set(items.filter(\.isMerged).map(\.id))
            loaded = true
        }
    }

    private func row(_ item: BranchCleanupItem) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { chosen.contains(item.id) },
                                     set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            Text(item.name).lineLimit(1)
            Spacer()
            tag(item.reason == .merged ? "Merged" : "Remote deleted", item.reason == .merged ? .green : .purple)
            if !item.isMerged { tag("Unmerged", .orange) }
        }
        .padding(.horizontal, 10).frame(height: 40)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2).background(tint.opacity(0.13), in: Capsule())
    }
}
