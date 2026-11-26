import GitSyncCore
import SwiftUI

/// Add, edit and remove remotes, and fetch or push to a single one.
struct RemotesSheet: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var remotes: [RemoteInfo] = []
    @State private var newName = ""
    @State private var newURL = ""
    @State private var editing: String?
    @State private var editURL = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remotes").font(.system(size: 17, weight: .semibold, design: .rounded))
            if remotes.isEmpty {
                Text("This repository has no remotes yet.").foregroundStyle(.secondary).padding(.vertical, 8)
            }
            ForEach(remotes) { remote in row(remote) }
            Divider()
            Text("Add Remote").font(.headline)
            HStack(spacing: 8) {
                field("name", text: $newName).frame(width: 110)
                field("https://… or git@…", text: $newURL)
                Button("Add") { run { try await store.repo.addRemote(newName.trimmingCharacters(in: .whitespaces), url: newURL); newName = ""; newURL = "" } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
        }
        .padding(22).frame(width: 560)
        .task { await reload() }
    }

    private func row(_ remote: RemoteInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "network").foregroundStyle(.secondary)
                Text(remote.name).fontWeight(.semibold)
                Spacer()
                Button("Fetch") { store.fetch(remote: remote.name); dismiss() }
                    .help("Fetch from \(remote.name)")
                Button("Push") { store.push(options: PushOptions(remote: remote.name)); dismiss() }
                    .disabled(store.status.branch == nil)
                    .help("Push the current branch to \(remote.name)")
                Menu {
                    Button("Edit URL…") { editing = remote.name; editURL = remote.fetchURL }
                    Button("Rename…") { rename(remote) }
                    Divider()
                    Button("Remove…", role: .destructive) { confirmRemove(remote) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            if editing == remote.name {
                HStack(spacing: 8) {
                    field("URL", text: $editURL)
                    Button("Save") { run { try await store.repo.setRemoteURL(remote.name, url: editURL); editing = nil } }
                    Button("Cancel") { editing = nil }
                }
            } else {
                Text(remote.fetchURL).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if remote.pushURL != remote.fetchURL {
                    Text("push: \(remote.pushURL)").font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.plain).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func reload() async {
        remotes = (try? await store.repo.remoteInfos()) ?? []
    }

    private func run(_ work: @escaping () async throws -> Void) {
        error = nil
        Task {
            do { try await work(); store.requestRefresh() } catch { self.error = error.localizedDescription }
            await reload()
        }
    }

    private func rename(_ remote: RemoteInfo) {
        let alert = NSAlert()
        alert.messageText = "Rename “\(remote.name)”"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = remote.name
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        run { try await store.repo.renameRemote(remote.name, to: name) }
    }

    private func confirmRemove(_ remote: RemoteInfo) {
        let alert = NSAlert()
        alert.messageText = "Remove “\(remote.name)”?"
        alert.informativeText = "Its remote-tracking branches are deleted here. Nothing changes on the server."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run { try await store.repo.removeRemote(remote.name) }
    }
}
