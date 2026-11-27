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
                            CheckIcon(state: status.overall ?? .neutral)
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
                                    CheckIcon(state: check.state).frame(width: 16)
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
        // While a run is still going, look again every 15 seconds so it turns green or red by itself.
        .task(id: sha) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if store.checksBySHA[sha]?.overall == .pending { store.loadChecks(sha: sha, force: true) }
            }
        }
    }
}

/// The icon for one check state. A running check shows a spinning arc instead of a clock.
private struct CheckIcon: View {
    let state: CheckState

    var body: some View {
        switch state {
        case .pending: Spinner()
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .neutral: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.72)
                .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees((t * 360 / 0.9).truncatingRemainder(dividingBy: 360)))
                .padding(1.5)
                .frame(width: 14, height: 14)
        }
        .accessibilityLabel("Running")
    }
}
