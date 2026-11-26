import Foundation

public enum SignatureFormat: String, Sendable {
    case gpg = "GPG", ssh = "SSH", x509 = "X.509"
}

public enum SignatureState: Equatable, Sendable {
    /// Valid signature from a trusted key.
    case good
    /// Valid signature, but the key's validity or trust is unknown (`%G?` = U).
    case goodUnknownTrust
    case bad
    case expiredSignature
    case expiredKey
    case revoked
    /// Signed, but git couldn't check it (missing public key, no allowed-signers file, …).
    case unverifiable

    public var isVerified: Bool { self == .good || self == .goodUnknownTrust }
}

/// What git reports about a commit's signature. Nil from `signature(of:)` means unsigned.
public struct CommitSignature: Equatable, Sendable {
    public var format: SignatureFormat
    public var state: SignatureState
    /// Signer identity (`%GS`), possibly empty.
    public var signer: String
    /// Key fingerprint or id (`%GK`), possibly empty.
    public var key: String

    public var title: String {
        switch state {
        case .good: "Verified \(format.rawValue) signature"
        case .goodUnknownTrust: "Valid \(format.rawValue) signature, key not trusted"
        case .bad: "Bad \(format.rawValue) signature"
        case .expiredSignature: "Expired \(format.rawValue) signature"
        case .expiredKey: "Signed with an expired key"
        case .revoked: "Signed with a revoked key"
        case .unverifiable: "\(format.rawValue) signature can’t be verified"
        }
    }
}

/// The repository's signing settings (`commit.gpgsign`, `gpg.format`, `user.signingkey`).
public struct SigningConfig: Equatable, Sendable {
    /// `commit.gpgsign`: commits are signed by default.
    public var signsByDefault: Bool
    public var format: SignatureFormat
    public var key: String?

    /// Whether signing has a chance of working without further setup.
    public var isConfigured: Bool { signsByDefault || (key?.isEmpty == false) }
}

extension GitRepository {
    public func signingConfig() async -> SigningConfig {
        func value(_ key: String) async -> String? {
            let out = try? await git.runString(["config", "--get", key], readOnly: true)
            let v = out?.trimmingCharacters(in: .whitespacesAndNewlines)
            return v?.isEmpty == false ? v : nil
        }
        let format: SignatureFormat = switch (await value("gpg.format"))?.lowercased() {
        case "ssh": .ssh
        case "x509": .x509
        default: .gpg
        }
        let sign = (await value("commit.gpgsign"))?.lowercased()
        return SigningConfig(signsByDefault: sign == "true" || sign == "yes" || sign == "on" || sign == "1",
                             format: format, key: await value("user.signingkey"))
    }

    /// The signature on `hash`, or nil when the commit is unsigned. Only signed commits are verified,
    /// so this is cheap for ordinary history.
    public func signature(of hash: String) async throws -> CommitSignature? {
        let raw = try await git.runString(["cat-file", "commit", hash], readOnly: true)
        let format: SignatureFormat
        if raw.contains("-----BEGIN SSH SIGNATURE-----") { format = .ssh }
        else if raw.contains("-----BEGIN PGP SIGNATURE-----") || raw.contains("-----BEGIN PGP MESSAGE-----") { format = .gpg }
        else if raw.contains("-----BEGIN SIGNED MESSAGE-----") { format = .x509 }
        else { return nil }

        let out = try await git.runString(["log", "-1", "--format=%G?%x1f%GS%x1f%GK", hash], readOnly: true)
        let f = out.trimmingCharacters(in: .newlines).split(separator: "\u{1f}", omittingEmptySubsequences: false)
        let code = f.first.map(String.init) ?? "E"
        let state: SignatureState = switch code {
        case "G": .good
        case "U": .goodUnknownTrust
        case "B": .bad
        case "X": .expiredSignature
        case "Y": .expiredKey
        case "R": .revoked
        default: .unverifiable
        }
        return CommitSignature(format: format, state: state,
                               signer: f.count > 1 ? String(f[1]) : "", key: f.count > 2 ? String(f[2]) : "")
    }
}
