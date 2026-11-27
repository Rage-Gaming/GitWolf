import GitWolfCore
import SwiftUI

/// Edits an interactive rebase: reorder by dragging, choose what happens to each commit.
struct RebaseSheet: View {
    let store: RepositoryStore
    @State var plan: RebasePlan
    @Environment(\.dismiss) private var dismiss

    init(store: RepositoryStore, plan: RebasePlan) {
        self.store = store
        _plan = State(initialValue: plan)
    }

    private var branch: String { store.status.branch ?? "HEAD" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Interactive Rebase").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Rewrites \(plan.items.count) commit\(plan.items.count == 1 ? "" : "s") on \(branch), oldest first. Drag to reorder. Squash and fixup fold into the commit above.")
                .font(.callout).foregroundStyle(.secondary)

            List {
                ForEach($plan.items) { $item in
                    row($item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                }
                .onMove { plan.items.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(height: min(340, CGFloat(plan.items.count) * 42 + 8))

            if let problem = plan.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            } else if plan.items.contains(where: { $0.action == .drop }) {
                Label("Dropped commits leave the branch; they stay reachable from the reflog.", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start Rebase") {
                    store.startRebase(plan)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.problem != nil || plan.isNoOp)
            }
        }
        .padding(22)
        .frame(width: 640)
    }

    private func row(_ item: Binding<RebaseItem>) -> some View {
        let action = item.wrappedValue.action
        return HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Menu {
                ForEach(RebaseAction.allCases) { choice in
                    Button(choice.title) { item.wrappedValue.action = choice }
                }
            } label: {
                Text(action.title).font(.caption.weight(.semibold)).foregroundStyle(tint(action))
                    .frame(width: 54)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(tint(action).opacity(0.14), in: Capsule())

            Text(item.wrappedValue.shortHash).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            if action == .reword {
                TextField("Message", text: item.message, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Text(item.wrappedValue.subject).lineLimit(1).truncationMode(.tail)
                    .strikethrough(action == .drop)
                    .foregroundStyle(action == .drop ? .secondary : .primary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, action.folds ? 22 : 0)
        .padding(.horizontal, 10).frame(minHeight: 36)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tint(_ action: RebaseAction) -> Color {
        switch action {
        case .pick: .secondary
        case .reword: .blue
        case .squash: .purple
        case .fixup: .teal
        case .drop: .red
        }
    }
}
