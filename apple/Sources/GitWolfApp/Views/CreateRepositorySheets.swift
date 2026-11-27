import AppKit
import GitWolfCore
import SwiftUI

enum WorkspaceSheet: String, Identifiable {
    case clone, create, account
    var id: String { rawValue }
}

extension View {
    func sheetField() -> some View {
        self.textFieldStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            content
        }
    }
}

/// Shows a folder path with a Choose… button.
private struct FolderField: View {
    @Binding var path: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Text((path as NSString).abbreviatingWithTildeInPath)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .sheetField()
            Button("Choose…", action: choose).buttonStyle(.bordered)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = prompt
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// Where new repositories go by default: the last used folder, else ~/Developer, else ~/Documents.
private func defaultLocation(_ stored: String) -> String {
    if !stored.isEmpty, FileManager.default.fileExists(atPath: stored) { return stored }
    let home = FileManager.default.homeDirectoryForCurrentUser
    let developer = home.appendingPathComponent("Developer")
    if FileManager.default.fileExists(atPath: developer.path) { return developer.path }
    return home.appendingPathComponent("Documents").path
}

// MARK: - Clone

struct CloneSheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newRepositoryLocation") private var storedLocation = ""

    @State private var url = ""
    @State private var name = ""
    @State private var autoName = ""
    @State private var location = ""
    @State private var task: Task<Void, Never>?
    @State private var progress = ""
    @State private var fraction: Double?
    @State private var error: String?
    @FocusState private var urlFocused: Bool
    @State private var accounts = AccountStore.shared
    @State private var source: ProviderAccount?
    @State private var repos: [RemoteRepository] = []
    @State private var loadingRepos = false
    @State private var repoError: String?
    @State private var query = ""
    @State private var showAdvanced = false
    @State private var shallow = false
    @State private var depth = 1
    @State private var filter = CloneOptions.Filter.full
    @State private var singleBranch = false
    @State private var branch = ""
    @State private var recurse = false

    private var options: CloneOptions {
        CloneOptions(depth: shallow ? max(1, depth) : nil, filter: filter, singleBranch: singleBranch,
                     branch: branch, recurseSubmodules: recurse)
    }

    private var filteredRepos: [RemoteRepository] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? repos : repos.filter { $0.fullName.lowercased().contains(q) || $0.description.lowercased().contains(q) }
    }

    private var isCloning: Bool { task != nil }
    private var canClone: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !name.trimmingCharacters(in: .whitespaces).isEmpty && !isCloning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Clone Repository").font(.system(size: 17, weight: .semibold, design: .rounded))

            if !accounts.accounts.isEmpty {
                HStack(spacing: 6) {
                    sourceButton(title: "URL", account: nil)
                    ForEach(accounts.accounts) { a in sourceButton(title: a.kind.title, account: a) }
                }
            }
            if let account = source {
                repoPicker(account)
            }

            LabeledField(label: "REPOSITORY URL") {
                TextField("https://github.com/owner/repo.git", text: $url)
                    .sheetField()
                    .focused($urlFocused)
                    .disabled(isCloning)
                    .onSubmit(start)
                    .onChange(of: url) { _, value in
                        // Keep the folder name in step with the URL until the user edits it.
                        if name.isEmpty || name == autoName {
                            autoName = GitRepository.suggestedName(forCloneURL: value)
                            name = autoName
                        }
                    }
            }
            LabeledField(label: "CLONE INTO") {
                FolderField(path: $location, prompt: "Choose where to clone").disabled(isCloning)
            }
            LabeledField(label: "FOLDER NAME") {
                TextField("repo", text: $name)
                    .sheetField()
                    .disabled(isCloning)
            }

            DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("Only the latest", isOn: $shallow)
                        Stepper(value: $depth, in: 1...100_000) { Text("\(depth) commit\(depth == 1 ? "" : "s")").monospacedDigit() }
                            .disabled(!shallow)
                    }
                    Picker("Download", selection: $filter) {
                        Text("Everything").tag(CloneOptions.Filter.full)
                        Text("No file contents until needed (blobless)").tag(CloneOptions.Filter.blobless)
                        Text("Commits only (treeless)").tag(CloneOptions.Filter.treeless)
                    }
                    HStack {
                        Toggle("Only one branch", isOn: $singleBranch)
                        TextField("branch (default)", text: $branch).sheetField()
                    }
                    Toggle("Also clone submodules", isOn: $recurse)
                }
                .padding(.top, 8)
            }
            .disabled(isCloning)

            if isCloning {
                VStack(alignment: .leading, spacing: 6) {
                    if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
                    Text(progress.isEmpty ? "Connecting…" : progress)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else if let error {
                Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(isCloning ? "Stop" : "Cancel", role: .cancel) {
                    if let task { task.cancel(); self.task = nil; progress = ""; fraction = nil } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: start)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canClone)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            location = defaultLocation(storedLocation)
            urlFocused = true
            // Offer a copied git URL.
            if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clip.contains("\n"), clip.hasSuffix(".git") || clip.hasPrefix("git@") || clip.contains("github.com/") || clip.contains("gitlab.com/") {
                url = clip
            }
        }
    }

    private func sourceButton(title: String, account: ProviderAccount?) -> some View {
        let selected = source?.id == account?.id
        return Button {
            source = account
            query = ""
            if let account { load(account) }
        } label: {
            HStack(spacing: 5) {
                if let account { ProviderTile(kind: account.kind, size: 16) } else { Image(systemName: "link").font(.system(size: 11)) }
                Text(title).font(.callout.weight(.medium)).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? Theme.brand.opacity(0.16) : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).disabled(isCloning)
    }

    @ViewBuilder private func repoPicker(_ account: ProviderAccount) -> some View {
        VStack(spacing: 6) {
            SearchField(text: $query, prompt: "Search \(account.kind.title) repositories")
            ScrollView {
                LazyVStack(spacing: 0) {
                    if loadingRepos {
                        ProgressView().controlSize(.small).padding(16)
                    } else if let repoError {
                        Text(repoError).font(.caption).foregroundStyle(.red).padding(12)
                    } else if filteredRepos.isEmpty {
                        Text("No repositories found").font(.caption).foregroundStyle(.secondary).padding(16)
                    }
                    ForEach(filteredRepos) { repo in
                        let selected = url == repo.httpsURL
                        Button {
                            url = repo.httpsURL
                            name = repo.name
                            autoName = repo.name
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(repo.fullName).fontWeight(.medium).lineLimit(1)
                                    if !repo.description.isEmpty {
                                        Text(repo.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .rowBackground(selected: selected, hovering: false, radius: 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 170)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func load(_ account: ProviderAccount) {
        repos = []
        repoError = nil
        guard account.kind.supportsRepositoryListing else {
            repoError = "\(account.kind.title) doesn't support browsing yet. Paste the repository URL below."
            return
        }
        loadingRepos = true
        Task {
            guard let token = await AccountStorage.secret(for: account) else {
                repoError = "The token for this account is missing from the Keychain."
                loadingRepos = false
                return
            }
            do {
                let list = try await ProviderClient(account: account, token: token).repositories()
                if source?.id == account.id { repos = list }
            } catch {
                if source?.id == account.id { repoError = error.localizedDescription }
            }
            loadingRepos = false
        }
    }

    private func start() {
        guard canClone else { return }
        error = nil
        progress = ""
        fraction = nil
        let source = url.trimmingCharacters(in: .whitespaces)
        let folder = name.trimmingCharacters(in: .whitespaces)
        let parent = URL(fileURLWithPath: location, isDirectory: true)
        let gitPath = AppSettings.shared.gitPath
        let host = RemoteLocation.parse(source)?.host

        task = Task {
            var credential: GitCredential?
            if let host { credential = await AccountStorage.credential(forHost: host) }
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let destination = try await GitRepository.clone(url: source, into: parent, name: folder, gitPath: gitPath,
                                                                  credential: credential, askpassPath: AskPass.path, options: options) { chunk in
                    // git separates live updates with carriage returns.
                    guard let last = chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last else { return }
                    let line = String(last)
                    Task { @MainActor in
                        progress = line
                        if let match = line.range(of: #"(\d+)%"#, options: .regularExpression),
                           let value = Double(line[match].dropLast()) { fraction = value / 100 }
                    }
                }
                storedLocation = location
                workspace.open(destination)
                dismiss()
            } catch is CancellationError {
                // Stopped by the user.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
                task = nil
            }
        }
    }
}

// MARK: - Create

struct CreateRepositorySheet: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newRepositoryLocation") private var storedLocation = ""

    @State private var name = ""
    @State private var location = ""
    @State private var branch = "main"
    @State private var error: String?
    @State private var working = false
    @FocusState private var nameFocused: Bool

    private var canCreate: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !working }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Repository").font(.system(size: 17, weight: .semibold, design: .rounded))

            LabeledField(label: "NAME") {
                TextField("my-project", text: $name).sheetField().focused($nameFocused).onSubmit(create)
            }
            LabeledField(label: "LOCATION") {
                FolderField(path: $location, prompt: "Choose where to create the repository")
            }
            LabeledField(label: "INITIAL BRANCH") {
                TextField("main", text: $branch).sheetField()
            }

            Text((location as NSString).abbreviatingWithTildeInPath + "/" + name.trimmingCharacters(in: .whitespaces))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)

            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear {
            location = defaultLocation(storedLocation)
            nameFocused = true
        }
    }

    private func create() {
        guard canCreate else { return }
        working = true
        error = nil
        let directory = URL(fileURLWithPath: location, isDirectory: true)
            .appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
        let initial = branch
        let gitPath = AppSettings.shared.gitPath
        Task {
            do {
                let created = try await GitRepository.initialize(at: directory, initialBranch: initial, gitPath: gitPath)
                storedLocation = location
                workspace.open(created)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
