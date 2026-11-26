import AppKit
import GitSyncCore
import SwiftUI

/// Review requests, mentions and assignments from your connected accounts.
struct NotificationsSheet: View {
    @State private var model = NotificationsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications").font(.system(size: 17, weight: .semibold, design: .rounded))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Reload")
            }
            ForEach(model.problems) { problem in
                Label("\(problem.account.kind.title) (\(problem.account.username)): \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !model.hasAccounts && model.entries.isEmpty {
                ContentUnavailableView("No Accounts", systemImage: "person.crop.circle.badge.questionmark",
                                       description: Text("Add a GitHub, GitLab or Gitea account in Settings → Accounts."))
                    .frame(height: 200)
            } else if model.entries.isEmpty {
                ContentUnavailableView(model.loadedAt == nil ? "Loading…" : "All Caught Up", systemImage: "bell.slash",
                                       description: Text("No review requests, mentions or assignments."))
                    .frame(height: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) { ForEach(model.entries) { row($0) } }
                }
                .frame(height: min(380, CGFloat(model.entries.count) * 62 + 8))
            }
            HStack {
                if !model.entries.isEmpty { Button("Mark All as Read") { model.markAllRead() } }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 560)
        .task { await model.refresh() }
    }

    private func row(_ entry: NotificationsStore.Entry) -> some View {
        let note = entry.note
        return Button {
            if let url = note.url { NSWorkspace.shared.open(url) }
            model.markRead(entry)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: note.isPullRequest ? "arrow.triangle.pull" : "smallcircle.filled.circle")
                    .foregroundStyle(.secondary).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title).fontWeight(.medium).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(note.repository)
                        if let date = note.updated {
                            Text("· \(date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(note.reason.title).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .foregroundStyle(tint(note.reason)).background(tint(note.reason).opacity(0.13), in: Capsule())
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open on \(entry.account.kind.title) and mark as read")
    }

    private func tint(_ reason: NotificationReason) -> Color {
        switch reason {
        case .reviewRequested: .orange
        case .mention: .blue
        case .assigned: .purple
        case .other: .secondary
        }
    }
}
