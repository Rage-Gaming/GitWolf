import AppKit
import GitSyncCore
import SwiftUI

/// CI result for one commit, loaded from the hosting provider. Shows nothing when there is no provider,
/// no checks, or the commit isn't on the server (for example it hasn't been pushed).
struct ChecksSection: View {
    let store: RepositoryStore
    let sha: String
    private var status: CIStatus? { store.checksBySHA[sha] }
    @State private var expanded = false

    var body: some View {
        Group {
            if let status, !status.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button { withAnimation(.snappy(duration: 0.15)) { expanded.toggle() } } label: {
                        HStack(spacing: 7) {
                            Image(systemName: icon(status.overall ?? .neutral)).foregroundStyle(tint(status.overall ?? .neutral))
                            Text(status.summary).fontWeight(.medium)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .font(.callout).pill()
                    }
                    .buttonStyle(.plain)
                    if expanded {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(status.checks) { check in
                                HStack(spacing: 8) {
                                    Image(systemName: icon(check.state)).foregroundStyle(tint(check.state)).frame(width: 16)
                                    Text(check.name).lineLimit(1)
                                    Spacer(minLength: 8)
                                    if let url = check.url {
                                        Button("Details") { NSWorkspace.shared.open(url) }.buttonStyle(.link).font(.caption)
                                    }
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func icon(_ state: CheckState) -> String {
        switch state {
        case .success: "checkmark.circle.fill"
        case .failure: "xmark.circle.fill"
        case .pending: "clock.fill"
        case .neutral: "minus.circle.fill"
        }
    }

    private func tint(_ state: CheckState) -> Color {
        switch state {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .neutral: .secondary
        }
    }
}
