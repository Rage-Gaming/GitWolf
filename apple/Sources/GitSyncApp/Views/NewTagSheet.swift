import GitSyncCore
import SwiftUI

/// Creates a lightweight tag, or an annotated one when a message is given, optionally pushing it.
struct NewTagSheet: View {
    let store: RepositoryStore
    let hash: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var message = ""
    @State private var push = false
    @FocusState private var focused: Bool

    private var remote: String? { store.remotes.first(where: { $0 == "origin" }) ?? store.remotes.first }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("At \(String(hash.prefix(7)))").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            TextField("v1.0.0", text: $name)
                .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .focused($focused)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Message (optional)", text: $message, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(3...6).padding(.horizontal, 12).padding(.vertical, 9)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                     ? "Without a message this is a lightweight tag." : "With a message this is an annotated tag, which records who tagged and when.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let remote { Toggle("Push to \(remote)", isOn: $push) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    store.createTag(name.trimmingCharacters(in: .whitespaces), at: hash, message: message, pushTo: push ? remote : nil)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding(22).frame(width: 420)
        .onAppear { focused = true }
    }
}
