import AppKit
import GitSyncCore
import SwiftUI

/// CI result for one commit, loaded from the hosting provider. Shows nothing when there is no provider,
/// no checks, or the commit isn't on the server (for example it hasn't been pushed).
struct ChecksSection: View {
    let store: RepositoryStore
    let sha: String
    var committed: Date?
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
                                    if store.canPerformCI(.cancel, on: check) { ciButton(.cancel, check) }
                                    if store.canPerformCI(.rerun, on: check) { ciButton(.rerun, check) }
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
        // While a run is going, or right after a push, look again every 15 seconds so the result appears by itself.
        .task(id: sha) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if store.shouldPollChecks(sha: sha, committed: committed) { store.loadChecks(sha: sha, force: true) }
            }
        }
    }

    private func ciButton(_ action: CIAction, _ check: CICheck) -> some View {
        let busy = store.isCIBusy(sha: sha, check: check)
        return Button { store.performCI(action, on: check, sha: sha) } label: {
            Image(systemName: action == .rerun ? "arrow.clockwise" : "stop.circle")
                .font(.system(size: 12, weight: .semibold)).frame(width: 20, height: 20)
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).disabled(busy).opacity(busy ? 0.4 : 1)
        .help(action == .rerun ? "Re-run this check" : "Cancel this run")
        .accessibilityLabel(action == .rerun ? "Re-run \(check.name)" : "Cancel \(check.name)")
    }
}

/// The icon for one check state. A running check shows a spinning arc instead of a clock.
private struct CheckIcon: View {
    let state: CheckState

    var body: some View {
        switch state {
        case .pending: CISpinner()
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .neutral: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// An indeterminate ring like the Windows one: the arc grows ahead, then the tail catches up, while the whole ring turns.
struct CISpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2
    private static let cycle = 1.4

    private func ease(_ x: Double) -> Double { let c = min(max(x, 0), 1); return c * c * (3 - 2 * c) }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let p = (t / Self.cycle).truncatingRemainder(dividingBy: 1)
            let head = ease(p / 0.7)
            let tail = ease((p - 0.3) / 0.7)
            Circle().trim(from: tail, to: max(head, tail + 0.001))
                .stroke(Color.orange, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(t * 360 / 1.1))
                .padding(lineWidth / 2 + 0.5)
                .frame(width: size, height: size)
        }
        .accessibilityLabel("Running")
    }
}
