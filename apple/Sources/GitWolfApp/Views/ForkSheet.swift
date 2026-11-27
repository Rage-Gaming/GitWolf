import GitWolfCore
import SwiftUI

/// Forks the repository on its hosting provider, then points this checkout at the fork.
struct ForkSheet: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var useAsOrigin = true
    @State private var remoteName = "fork"
    @State private var working = false
    @State private var error: String?

    private var provider: String { store.providerTitle ?? "the provider" }
    private var hasUpstream: Bool { store.remotes.contains("upstream") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Fork on \(provider)").font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("Creates your own copy of \(store.remoteLocation?.path ?? "this repository") on \(provider). It uses the account you connected.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("", selection: $useAsOrigin) {
                Text("Use the fork as origin, keep the original as “upstream”").tag(true)
                Text("Add the fork as another remote").tag(false)
            }
            .pickerStyle(.radioGroup).labelsHidden()
            if useAsOrigin && hasUpstream {
                Label("A remote named “upstream” already exists. Add the fork as another remote instead.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !useAsOrigin {
                TextField("Remote name", text: $remoteName)
                    .textFieldStyle(.plain).padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Forking…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Fork", action: run).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(working || (useAsOrigin && hasUpstream) || (!useAsOrigin && remoteName.trimmingCharacters(in: .whitespaces).isEmpty))
            }
        }
        .padding(22).frame(width: 480)
        .onAppear { if hasUpstream { useAsOrigin = false; remoteName = "fork" } }
    }

    private func run() {
        working = true
        error = nil
        let mode: ForkRemoteMode = useAsOrigin ? .useAsOrigin : .addRemote(remoteName.trimmingCharacters(in: .whitespaces))
        let repo = store.repo
        Task {
            do {
                guard let (client, path) = await store.providerClient() else { throw ProviderError.unsupported("No account for this repository’s host.") }
                let fork = try await client.fork(repoPath: path)
                let remote = try await repo.adoptFork(fork, mode: mode, fetch: false)
                do {
                    try await repo.fetch(remote: remote)
                } catch {
                    // GitHub copies in the background; give it a moment and try the fetch once more.
                    try await Task.sleep(for: .seconds(4))
                    try await repo.fetch(remote: remote)
                }
                store.requestRefresh()
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
