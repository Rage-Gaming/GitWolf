import GitWolfCore
import Observation
import SwiftUI

/// Loads the contributor list from GitHub's public API (no credentials, no cookies) and keeps the last answer for
/// offline use. Refreshed at most once a day.
@MainActor @Observable
final class ContributorsStore {
    static let shared = ContributorsStore()
    private(set) var people: [Contributor]
    private(set) var loading = false
    private static let cacheKey = "contributorsCache"
    private static let stampKey = "contributorsFetchedAt"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([Contributor].self, from: data), !cached.isEmpty {
            people = cached
        } else {
            people = Contributors.fallback
        }
    }

    func refresh(force: Bool = false) async {
        let last = UserDefaults.standard.object(forKey: Self.stampKey) as? Date ?? .distantPast
        guard !loading, force || Date().timeIntervalSince(last) > 86_400 else { return }
        loading = true
        defer { loading = false }
        var request = URLRequest(url: Contributors.apiURL)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GitWolf", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return }
        let parsed = Contributors.parse(data)
        people = parsed
        UserDefaults.standard.set(try? JSONEncoder().encode(parsed), forKey: Self.cacheKey)
        UserDefaults.standard.set(Date(), forKey: Self.stampKey)
    }
}

/// Help > Contributors: everyone who has contributed to GitWolf, with a link to each profile.
struct ContributorsView: View {
    @State private var store = ContributorsStore.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                if let art = BrandArt.mark?.copy() as? NSImage {
                    Image(nsImage: art).resizable().renderingMode(.template).scaledToFit().frame(height: 34)
                        .foregroundStyle(Theme.brand).accessibilityHidden(true)
                }
                Text("Contributors").font(.title2.weight(.semibold))
                Text("GitWolf is built by these people. Thank you.").font(.callout).foregroundStyle(.secondary)
            }
            .padding(.top, 22).padding(.bottom, 16)

            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.people) { person in row(person) }
                }
                .padding(.vertical, 6)
            }
            Divider()
            HStack {
                if store.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Become a Contributor") {
                    openURL(AboutPanel.repository.appendingPathComponent("blob/main/CONTRIBUTING.md"))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 420, height: 520)
        .task { await store.refresh() }
    }

    private func row(_ person: Contributor) -> some View {
        Button {
            if let url = person.profileURL { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                AvatarView(name: person.login, email: person.login, size: 36, url: person.avatarURL.map(sized))
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.login).font(.body.weight(.medium))
                    if Contributors.isMaintainer(person) {
                        Text("Maintainer").font(.caption).foregroundStyle(Theme.brand)
                    }
                }
                Spacer()
                if person.contributions > 0 {
                    Text("\(person.contributions) \(person.contributions == 1 ? "commit" : "commits")")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(person.login), \(person.contributions) commits")
        .help("Open \(person.login) on GitHub")
    }

    /// Asks GitHub for a 96 px picture, enough for a 36 pt avatar on a retina display.
    private func sized(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = parts.queryItems ?? []
        items.removeAll { $0.name == "s" }
        items.append(URLQueryItem(name: "s", value: "96"))
        parts.queryItems = items
        return parts.url ?? url
    }
}
