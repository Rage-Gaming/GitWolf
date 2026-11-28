import Charts
import GitWolfCore
import SwiftUI

/// Commits over time, who contributes, which files change most, and who works where.
struct InsightsSheet: View {
    let store: RepositoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var insights: RepositoryInsights?
    @State private var failure: String?
    @State private var tab = Tab.contributors

    enum Tab: String, CaseIterable, Identifiable {
        case contributors = "Contributors", hot = "Hot files", churn = "Churn", ownership = "Ownership"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Statistics").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text(store.name).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let failure {
                Text(failure).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
            } else if let insights {
                if insights.commits == 0 {
                    Text("No commits yet.").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 300)
                } else { content(insights) }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .padding(22)
        .frame(width: 680)
        .task {
            do { insights = try await store.repo.insights() } catch { failure = error.localizedDescription }
        }
    }

    @ViewBuilder private func content(_ r: RepositoryInsights) -> some View {
        HStack(spacing: 10) {
            figure("\(r.commits.formatted())\(r.truncated ? "+" : "")", "commits")
            figure(r.contributors.count.formatted(), "contributors")
            figure("+\(r.added.formatted())", "lines added")
            figure("−\(r.deleted.formatted())", "lines removed")
        }
        if r.truncated {
            Text("Only the most recent commits were read, so older history is not counted.").font(.caption).foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("COMMITS PER WEEK").font(.system(size: 10.5, weight: .semibold)).tracking(0.8).foregroundStyle(.secondary)
            Chart(recent(r.weeks)) { week in
                BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Commits", week.commits))
                    .foregroundStyle(Theme.brand)
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 6)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits)) } }
            .frame(height: 120)
        }

        Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden()

        ScrollView {
            LazyVStack(spacing: 2) {
                switch tab {
                case .contributors:
                    let top = Double(r.contributors.first?.commits ?? 1)
                    ForEach(r.contributors.prefix(50)) { c in
                        row(c.name, detail: c.email, value: "\(c.commits) commits", fraction: Double(c.commits) / top,
                            extra: "+\(c.added.formatted()) −\(c.deleted.formatted())")
                    }
                case .hot:
                    let top = Double(r.hotFiles.first?.commits ?? 1)
                    ForEach(r.hotFiles.prefix(50)) { f in row(f.path, value: "\(f.commits) commits", fraction: Double(f.commits) / top) }
                case .churn:
                    let top = Double(r.churnFiles.first?.churn ?? 1)
                    ForEach(r.churnFiles.prefix(50)) { f in
                        row(f.path, value: "\(f.churn.formatted()) lines", fraction: Double(f.churn) / top,
                            extra: "+\(f.added.formatted()) −\(f.deleted.formatted())")
                    }
                case .ownership:
                    ForEach(r.ownership.prefix(50)) { o in
                        row(o.folder, detail: "\(o.owner) · \(Int((o.share * 100).rounded()))% of changes", value: "\(o.lines.formatted()) lines", fraction: o.share)
                    }
                }
            }
        }
        .frame(height: 220)
    }

    private func recent(_ weeks: [RepositoryInsights.Week]) -> [RepositoryInsights.Week] { Array(weeks.suffix(52)) }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func row(_ title: String, detail: String? = nil, value: String, fraction: Double, extra: String? = nil) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 12)
            if let extra { Text(extra).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            Text(value).font(.callout).monospacedDigit().frame(width: 90, alignment: .trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.brand).frame(width: max(3, g.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(width: 90, height: 6)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }
}
