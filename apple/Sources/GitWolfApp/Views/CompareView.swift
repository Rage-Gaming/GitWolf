import GitWolfCore
import SwiftUI

/// Compare any two branches, tags or commits: what the second has that the first doesn't.
struct CompareView: View {
    @Bindable var store: RepositoryStore
    @State private var showCommits = true

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Compare").font(.system(size: 17, weight: .semibold, design: .rounded))
            HStack(spacing: 8) {
                refField("Base", $store.compareFrom)
                Button { store.swapCompare() } label: { Image(systemName: "arrow.left.arrow.right") }
                    .buttonStyle(.plain).help("Swap")
                refField("Compare", $store.compareTo)
            }
            HStack {
                Toggle("Only changes since the common ancestor", isOn: $store.compareSinceAncestor)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .onChange(of: store.compareSinceAncestor) { if store.comparison != nil { store.runCompare() } }
                Spacer()
                Button("Compare") { store.runCompare() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .disabled(store.compareFrom.isEmpty || store.compareTo.isEmpty || store.isComparing)
            }
        }
        .padding(14)
    }

    private func refField(_ placeholder: String, _ text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(.callout, design: .monospaced))
                .onSubmit { store.runCompare() }
            Menu {
                Section("Branches") { ForEach(store.localBranches) { b in Button(b.name) { text.wrappedValue = b.name } } }
                if !store.remoteBranches.isEmpty {
                    Section("Remote") { ForEach(store.remoteBranches) { b in Button(b.name) { text.wrappedValue = b.name } } }
                }
                if !store.tags.isEmpty {
                    Section("Tags") { ForEach(store.tags) { t in Button(t.name) { text.wrappedValue = t.name } } }
                }
                Button("HEAD") { text.wrappedValue = "HEAD" }
            } label: { Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        if store.isComparing && store.comparison == nil {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = store.compareError {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let c = store.comparison {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summary(c)
                    section("Commits", c.commits.count, expanded: $showCommits) {
                        ForEach(c.commits) { commit in
                            HStack(spacing: 8) {
                                Text(commit.shortHash).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                Text(commit.subject).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(commit.authorName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .padding(.horizontal, 8).frame(height: 28)
                            .contentShape(Rectangle())
                            .onTapGesture { store.reveal(hash: commit.hash) }
                            .help("Show in History")
                        }
                    }
                    section("Files", c.files.count, expanded: .constant(true)) {
                        ForEach(c.files) { change in
                            CommitFileRow(change: change, selected: store.selectedTarget?.path == change.path) {
                                store.selectChange(change, source: .compare(base: c.base, head: c.head))
                            }
                        }
                    }
                }
                .padding(10)
            }
        } else {
            ContentUnavailableView("Compare Two Refs", systemImage: "arrow.left.arrow.right",
                                   description: Text("Pick a base and a branch, tag or commit to compare it with."))
        }
    }

    private func summary(_ c: RefComparison) -> some View {
        HStack(spacing: 8) {
            pill("\(c.ahead) ahead", .green, show: true)
            pill("\(c.behind) behind", .orange, show: true)
            Text("\(store.compareTo) vs \(store.compareFrom)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 6)
    }

    private func pill(_ text: String, _ tint: Color, show: Bool) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3).background(tint.opacity(0.13), in: Capsule())
    }

    private func section<Content: View>(_ title: String, _ count: Int, expanded: Binding<Bool>,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: 6) {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(count)").font(.caption2.weight(.bold)).padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, 6)
            }
            .buttonStyle(.plain)
            if expanded.wrappedValue { content() }
        }
    }
}
