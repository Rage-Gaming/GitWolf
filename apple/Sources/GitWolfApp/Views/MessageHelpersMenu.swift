import GitWolfCore
import SwiftUI

/// A small menu above the commit button: conventional prefix, issue reference, template, recent messages, spelling.
struct MessageHelpersMenu: View {
    @Bindable var store: RepositoryStore
    @AppStorage("spellCheckCommitMessages") private var spellCheck = true
    @State private var template: String?
    @State private var recent: [String] = []

    private var scopes: [String] { CommitMessage.suggestedScopes(for: store.status.staged.map(\.path)) }
    private var openIssues: [CollabItem] { store.issues.items.filter { $0.state == .open }.prefix(15).map { $0 } }

    var body: some View {
        Menu {
            Menu("Type Prefix") {
                ForEach(CommitMessage.conventionalTypes) { type in
                    Button("\(type.name) — \(type.summary)") { setPrefix(type.name, scope: nil) }
                }
                if !scopes.isEmpty {
                    Divider()
                    ForEach(scopes, id: \.self) { scope in
                        Menu("Scope: \(scope)") {
                            ForEach(CommitMessage.conventionalTypes) { type in
                                Button("\(type.name)(\(scope))") { setPrefix(type.name, scope: scope) }
                            }
                        }
                    }
                }
            }
            Menu("Reference Issue") {
                if openIssues.isEmpty {
                    Text(store.providerTitle == nil ? "No provider connected" : "No open issues loaded")
                } else {
                    ForEach(openIssues) { issue in
                        Menu("#\(issue.number) \(issue.title)") {
                            Button("Closes #\(issue.number)") { reference("Closes", issue.number) }
                            Button("Refs #\(issue.number)") { reference("Refs", issue.number) }
                        }
                    }
                }
            }
            if let template {
                Button("Use Repository Template") { store.draftMessage = template }
            }
            if !recent.isEmpty {
                Menu("Reuse Recent Message") {
                    ForEach(recent, id: \.self) { message in
                        Button(String((message.components(separatedBy: "\n").first ?? message).prefix(60))) { store.draftMessage = message }
                    }
                }
            }
            Divider()
            Toggle("Check Spelling While Typing", isOn: $spellCheck)
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Commit message helpers")
        .accessibilityLabel("Commit message helpers")
        .task(id: store.status.staged.count) {
            template = await store.repo.commitTemplate()
            recent = await store.repo.recentMessages()
        }
    }

    private func setPrefix(_ type: String, scope: String?) {
        store.draftMessage = CommitMessage.applyPrefix(type: type, scope: scope, to: store.draftMessage)
    }

    private func reference(_ keyword: String, _ number: Int) {
        store.draftMessage = CommitMessage.addReference(keyword: keyword, number: number, to: store.draftMessage)
    }
}
