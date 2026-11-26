import GitSyncCore
import SwiftUI

/// Everything about one file: the commits that changed it (with the diff of each) and who wrote each line.
struct FileHistorySheet: View {
    let store: RepositoryStore
    let path: String
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable { case history = "History", blame = "Blame" }
    #if DEBUG
    @State private var tab: Tab = ProcessInfo.processInfo.environment["GITSYNC_TAB"] == "blame" ? .blame : .history
    #else
    @State private var tab: Tab = .history
    #endif
    @State private var history: [Commit] = []
    @State private var selected: Commit?
    @State private var diff: FileDiff?
    @State private var blame: [BlameLine] = []
    @State private var blameError: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                FileIconView(path: path)
                Text(path).font(.system(.callout, design: .monospaced).weight(.semibold)).lineLimit(1).truncationMode(.head)
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).frame(height: 52)
            Divider()
            if !loaded {
                ProgressView().controlSize(.small).frame(maxHeight: .infinity)
            } else if tab == .history {
                historyView
            } else {
                blameView
            }
        }
        .frame(width: 1000, height: 640)
        .task {
            let repo = store.repo
            history = (try? await repo.fileHistory(path: path, remotes: Set(store.remotes))) ?? []
            do { blame = try await repo.blame(path: path) } catch { blameError = error.localizedDescription }
            loaded = true
            if let first = history.first { await select(first) }
        }
    }

    // MARK: History

    private var historyView: some View {
        HStack(spacing: 0) {
            if history.isEmpty {
                ContentUnavailableView("No History", systemImage: "clock", description: Text("This file has no commits yet."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(history) { commit in
                            HStack(spacing: 10) {
                                AvatarView(name: commit.authorName, email: commit.authorEmail, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(commit.subject).lineLimit(1)
                                    Text("\(commit.authorName) · \(commit.shortHash) · \(commit.date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).frame(height: 46)
                            .background(selected == commit ? Color.accentColor.opacity(0.16) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await select(commit) } }
                            .contextMenu {
                                Button("Show in History") { dismiss(); store.reveal(hash: commit.hash) }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(width: 360)
                Divider()
                DiffPane(diff: diff, path: path).frame(maxWidth: .infinity)
            }
        }
    }

    private func select(_ commit: Commit) async {
        selected = commit
        diff = nil
        let result = try? await store.repo.fileDiff(path: path, at: commit.hash)
        if selected == commit { diff = result ?? .empty }
    }

    // MARK: Blame

    private var blameView: some View {
        Group {
            if let blameError {
                ContentUnavailableView("Can’t Blame This File", systemImage: "person.fill.questionmark",
                                       description: Text(blameError))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(blame.enumerated()), id: \.element.id) { index, line in
                            let first = index == 0 || blame[index - 1].hash != line.hash
                            BlameRow(line: line, showsGutter: first) {
                                if !line.isUncommitted { dismiss(); store.reveal(hash: line.hash) }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct BlameRow: View {
    let line: BlameLine
    let showsGutter: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            Group {
                if showsGutter {
                    HStack(spacing: 6) {
                        Text(line.isUncommitted ? "Not committed" : line.author).fontWeight(.medium).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(line.isUncommitted ? "" : line.date.formatted(.dateTime.year().month(.abbreviated).day()))
                            .foregroundStyle(.secondary)
                    }
                    .help(line.isUncommitted ? "Uncommitted change" : "\(line.shortHash) · \(line.summary)")
                    .onTapGesture(perform: open)
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 8).frame(width: 250, alignment: .leading)
            Text("\(line.line)").font(.system(size: 12, design: .monospaced)).foregroundStyle(.tertiary)
                .frame(width: 44, alignment: .trailing).padding(.trailing, 10)
            Text(line.text.isEmpty ? " " : line.text).font(.system(size: 12, design: .monospaced))
                .lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 19)
        .padding(.top, showsGutter ? 5 : 0)
    }

    private var tint: Color {
        line.isUncommitted ? .orange : avatarColor(for: line.hash)
    }
}
