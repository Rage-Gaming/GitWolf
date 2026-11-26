import AppKit
import GitSyncCore
import SwiftUI

/// Review requests, mentions and assignments from your connected accounts.
struct NotificationsSheet: View {
    @State private var model = NotificationsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520)
        .task { await model.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell.fill")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text("Notifications").font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Review requests, mentions and assignments").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoading { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.bordered).controlSize(.regular).help("Reload")
                .accessibilityLabel("Reload")
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.problems) { problem in
                Label("\(problem.account.kind.title) (\(problem.account.username)): \(problem.message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
            }
            if !model.hasAccounts && model.entries.isEmpty {
                empty("person.crop.circle.badge.questionmark", "No accounts connected",
                      "Add a GitHub, GitLab or Gitea account in Settings → Accounts.")
            } else if model.entries.isEmpty {
                if model.loadedAt == nil { empty("bell", "Loading…", "Checking your accounts.") }
                else { empty("checkmark.circle", "All caught up", "Nothing needs your attention right now.") }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) { ForEach(model.entries) { row($0) } }
                        .padding(.vertical, 2)
                }
                .frame(height: min(360, CGFloat(model.entries.count) * 66))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, model.entries.isEmpty ? 12 : 14)
    }

    private func empty(_ symbol: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(Color.primary.opacity(0.06), in: Circle())
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    private var footer: some View {
        HStack {
            if !model.entries.isEmpty { Button("Mark All as Read") { model.markAllRead() }.buttonStyle(.bordered) }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .padding(.horizontal, 20).padding(.vertical, 14)
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
