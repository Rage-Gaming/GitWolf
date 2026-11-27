import GitWolfCore
import SwiftUI

/// Shown while a merge, rebase, cherry-pick or revert is waiting: what is happening, what is left
/// to resolve, and the three ways out.
struct OperationBanner: View {
    @Bindable var store: RepositoryStore
    let operation: InProgressOperation
    @State private var confirmAbort = false

    private var conflicts: Int { store.status.conflicted.count }
    private var canContinue: Bool { conflicts == 0 && !store.isBusy }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(operation.title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if conflicts > 0 {
                Button("Show Conflicts") { store.mode = .changes }.buttonStyle(.bordered)
            }
            if operation.canSkip {
                Button("Skip") { store.skipOperation() }.buttonStyle(.bordered).disabled(store.isBusy)
                    .help("Drop the commit that is being applied and move on")
            }
            Button("Abort", role: .destructive) { confirmAbort = true }.buttonStyle(.bordered).disabled(store.isBusy)
            Button("Continue") { store.continueOperation() }
                .buttonStyle(.borderedProminent).disabled(!canContinue)
                .help(conflicts > 0 ? "Resolve and stage every conflicted file first" : "Continue the \(operation.verb.lowercased())")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        .confirmationDialog("Abort the \(operation.verb.lowercased())?", isPresented: $confirmAbort, titleVisibility: .visible) {
            Button("Abort and Go Back", role: .destructive) { store.abortOperation() }
        } message: {
            Text("Everything done by this \(operation.kind == .merge ? "merge" : "operation") so far, including conflict resolutions, is thrown away and the repository returns to how it was before.")
        }
    }

    private var icon: String {
        switch operation.kind {
        case .merge: "arrow.triangle.merge"
        case .rebase: "arrow.triangle.swap"
        case .cherryPick: "arrow.uturn.right"
        case .revert: "arrow.uturn.backward"
        case .am: "envelope.open"
        }
    }

    private var detail: String {
        if conflicts > 0 { return "\(conflicts) conflicted file\(conflicts == 1 ? "" : "s") to resolve, then stage them and continue." }
        return "No conflicts left. Continue to finish."
    }
}
