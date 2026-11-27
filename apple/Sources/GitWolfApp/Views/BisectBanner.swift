import GitWolfCore
import SwiftUI

/// Guides a bisect: choosing the first bad and good commits, then marking each commit git asks you to test.
struct BisectBanner: View {
    @Bindable var store: RepositoryStore

    private var head: Commit? { store.commits.first { $0.hash == store.status.headOID } }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "scope").font(.system(size: 15, weight: .semibold)).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            if let bad = store.bisect.firstBad {
                Button("Show Commit") { store.mode = .history; store.selectCommit(bad) }.buttonStyle(.bordered)
                Button("Finish") { store.stopBisect() }.buttonStyle(.borderedProminent)
            } else if store.bisect.isActive {
                Button("Skip") { store.bisectMarkCurrent(.skip) }.buttonStyle(.bordered).disabled(store.isBusy)
                    .help("Can't test this commit; try another")
                Button("Bad") { store.bisectMarkCurrent(.bad) }.buttonStyle(.bordered).disabled(store.isBusy)
                    .help("The bug is present in this commit")
                Button("Good") { store.bisectMarkCurrent(.good) }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                    .help("The bug is not present in this commit")
                Button("Stop") { store.stopBisect() }.buttonStyle(.bordered).disabled(store.isBusy)
            } else {
                Button("Cancel") { store.stopBisect() }.buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.purple.opacity(0.35)))
    }

    private var title: String {
        if let bad = store.bisect.firstBad { return "First bad commit: \(bad.prefix(7))" }
        if store.bisect.isActive { return "Bisecting" }
        return "Bisect: pick a \(store.bisectBad == nil ? "bad" : "good") commit"
    }

    private var detail: String {
        if let bad = store.bisect.firstBad {
            return store.commits.first { $0.hash == bad }?.subject ?? "git narrowed the bug down to this commit."
        }
        if store.bisect.isActive {
            let testing = head.map { "Testing \($0.shortHash) “\($0.subject)”. " } ?? ""
            return testing + "Build and run it, then mark it Good or Bad." + (store.bisectProgress.map { " \($0)." } ?? "")
        }
        return store.bisectBad == nil
            ? "Right-click a commit that has the bug and choose “Bisect: This Is Bad”."
            : "Now right-click an older commit that worked and choose “Bisect: This Is Good”."
    }
}

/// Shown for a shallow clone: history is cut off, with a button to download the rest.
struct ShallowBanner: View {
    let store: RepositoryStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors").foregroundStyle(.secondary)
            Text("Shallow clone: older history isn't downloaded.").font(.callout)
            Spacer()
            Button("Fetch Full History") { store.fetchFullHistory() }.disabled(store.isBusy)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
