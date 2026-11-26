import AppKit
import GitSyncCore
import SwiftUI

/// Flat, single-colour tile standing in for a provider logo.
struct ProviderTile: View {
    let kind: ProviderKind
    var size: CGFloat = 30

    private var color: Color {
        switch kind {
        case .github: Color(red: 0.14, green: 0.16, blue: 0.20)
        case .gitlab: Color(red: 0.89, green: 0.35, blue: 0.14)
        case .bitbucket: Color(red: 0.15, green: 0.45, blue: 0.90)
        case .gitea: Color(red: 0.30, green: 0.62, blue: 0.20)
        case .azure: Color(red: 0.0, green: 0.47, blue: 0.83)
        }
    }
    @Environment(\.colorScheme) private var scheme

    /// GitHub's mark is black, so on dark appearance it sits on a light tile to stay visible.
    private var lightTile: Bool { kind == .github && scheme == .dark }

    var body: some View {
        let hex = lightTile ? "#14161A" : "#FFFFFF"
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(lightTile ? Color.white : color)
            .frame(width: size, height: size)
            .overlay {
                if let image = ProviderLogo.image(kind, hex: hex) {
                    Image(nsImage: image).resizable().scaledToFit().padding(size * 0.2)
                }
            }
    }
}

// MARK: - Settings pane

struct AccountsSettings: View {
    private var store = AccountStore.shared
    @State private var adding = false
    @State private var removing: ProviderAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CONNECTED ACCOUNTS")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(.secondary).padding(.horizontal, 4)
                VStack(spacing: 0) {
                    if store.accounts.isEmpty {
                        Text("No accounts yet. Add one to clone private repositories and sync with your host.")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider().padding(.leading, 54) }
                        HStack(spacing: 12) {
                            ProviderTile(kind: account.kind)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.kind.title).fontWeight(.medium)
                                Text(account.username.isEmpty ? account.host : "@\(account.username) · \(account.host)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { removing = account }
                                .buttonStyle(.plain).font(.callout).pill()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                    }
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            }

            HStack {
                Button { adding = true } label: {
                    Label("Add Account…", systemImage: "plus").font(.callout.weight(.medium))
                }
                .buttonStyle(.plain).pill()
                Spacer()
            }

            Text("Tokens are stored in your macOS Keychain and handed to Git only for matching hosts. They are never written into URLs or config files.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $adding) { AddAccountSheet() }
        .confirmationDialog("Remove this account?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { account in
            Button("Remove \(account.kind.title) Account", role: .destructive) { store.remove(account) }
        } message: { account in
            Text("The token for \(account.host) will be deleted from the Keychain.")
        }
    }
}

// MARK: - Add account

struct AddAccountSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var kind = ProviderKind.github
    @State private var host = ProviderKind.github.defaultHost
    @State private var username = ""
    @State private var token = ""
    @State private var usePassword = false
    @State private var working = false
    @State private var error: String?

    private var cleanHost: String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://", "http://"] where h.hasPrefix(prefix) { h.removeFirst(prefix.count) }
        if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
        while h.hasSuffix("/") { h.removeLast() }
        return h
    }
    private var scheme: String? {
        host.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://") ? "http" : nil
    }
    private var canAdd: Bool {
        !cleanHost.isEmpty && !token.trimmingCharacters(in: .whitespaces).isEmpty
            && (!(kind.needsUsername || usePassword) || !username.trimmingCharacters(in: .whitespaces).isEmpty) && !working
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account").font(.system(size: 17, weight: .semibold, design: .rounded))

            HStack(spacing: 8) {
                ForEach(ProviderKind.allCases) { item in
                    Button {
                        kind = item
                        if host.isEmpty || ProviderKind.allCases.contains(where: { $0.defaultHost == host }) { host = item.defaultHost }
                        error = nil
                    } label: {
                        VStack(spacing: 5) {
                            ProviderTile(kind: item, size: 34)
                            Text(item == .gitea ? "Gitea" : item == .azure ? "Azure DevOps" : item.title)
                                .font(.caption2).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(kind == item ? Theme.brand.opacity(0.14) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(kind == item ? Theme.brand.opacity(0.6) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Picker("", selection: $usePassword) {
                Text(kind.secretName == "Access token" ? "Access token" : "Token / app password").tag(false)
                Text("Username & password").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()

            field("HOST") {
                TextField(kind.defaultHost, text: $host).textFieldStyle(.plain)
                    .onChange(of: host) { _, value in
                        // Enterprise / self-managed servers: pick the provider from the hostname.
                        var h = value.lowercased()
                        for p in ["https://", "http://"] where h.hasPrefix(p) { h.removeFirst(p.count) }
                        if let guessed = ProviderKind.guess(host: h), guessed != kind { kind = guessed }
                    }
            }
            Text(verbatim: "For GitHub Enterprise, GitLab self-managed, Gitea or Bitbucket Data Center, enter your server, e.g. git.company.com or https://git.company.com:8443.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if kind.needsUsername || usePassword {
                field("USERNAME") { TextField("username", text: $username).textFieldStyle(.plain) }
            }
            field(usePassword ? "PASSWORD" : kind.secretName.uppercased()) {
                SecureField("Paste here", text: $token).textFieldStyle(.plain).onSubmit(add)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(usePassword ? "Many hosts (GitHub, GitLab) no longer accept passwords for Git over HTTPS; use a token there."
                                 : kind.scopeHint).font(.caption).foregroundStyle(.secondary)
                if !usePassword, let link = kind.tokenPageURL(host: cleanHost) {
                    Button("Create a \(kind.secretName.lowercased()) on \(cleanHost) ↗") { NSWorkspace.shared.open(link) }
                        .buttonStyle(.link).font(.caption)
                }
            }

            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }

            HStack {
                if working { ProgressView().controlSize(.small); Text("Verifying…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 11, weight: .semibold)).tracking(0.4).foregroundStyle(.secondary)
            content()
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func add() {
        guard canAdd else { return }
        working = true
        error = nil
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var account = ProviderAccount(kind: kind, host: cleanHost, username: username.trimmingCharacters(in: .whitespaces),
                                      usesPassword: usePassword, scheme: scheme)
        let password = usePassword
        Task {
            do {
                if kind.supportsRepositoryListing {
                    do {
                        let login = try await ProviderClient(account: account, token: secret).currentUser()
                        if !kind.needsUsername && !password { account.username = login }
                    } catch ProviderError.unauthorized where password && (kind == .github || kind == .gitlab) {
                        // These APIs reject passwords; Git itself may still accept them, so keep the account.
                    }
                } else if account.username.isEmpty {
                    account.username = "git"
                }
                try AccountStore.shared.add(account, token: secret)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                working = false
            }
        }
    }
}
