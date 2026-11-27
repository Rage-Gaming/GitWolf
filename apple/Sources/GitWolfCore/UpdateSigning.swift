import CryptoKit
import Foundation

/// Signs and verifies release archives for the in-app updater (Sparkle's EdDSA scheme: Ed25519 over the
/// raw bytes of the archive). The public key goes into the app's Info.plist as `SUPublicEDKey`; the
/// private key never leaves the maintainer's Keychain or the release workflow's secrets.
public enum UpdateSigning {
    public struct KeyPair: Sendable {
        /// Base64 of the 32-byte private seed. Keep secret.
        public let privateKey: String
        /// Base64 of the 32-byte public key, as `SUPublicEDKey` expects.
        public let publicKey: String
    }

    public enum Failure: LocalizedError {
        case badKey
        public var errorDescription: String? { "The update signing key is not valid base64 of a 32-byte Ed25519 key." }
    }

    public static func generate() -> KeyPair {
        let key = Curve25519.Signing.PrivateKey()
        return KeyPair(privateKey: key.rawRepresentation.base64EncodedString(),
                       publicKey: key.publicKey.rawRepresentation.base64EncodedString())
    }

    public static func publicKey(forPrivateKey base64: String) throws -> String {
        try privateKey(base64).publicKey.rawRepresentation.base64EncodedString()
    }

    /// Base64 signature of `data`, as `sparkle:edSignature` expects.
    public static func sign(_ data: Data, privateKey base64: String) throws -> String {
        try privateKey(base64).signature(for: data).base64EncodedString()
    }

    public static func verify(_ signature: String, for data: Data, publicKey base64: String) -> Bool {
        guard let keyData = Data(base64Encoded: base64), let sig = Data(base64Encoded: signature),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    private static func privateKey(_ base64: String) throws -> Curve25519.Signing.PrivateKey {
        guard let data = Data(base64Encoded: base64.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data) else { throw Failure.badKey }
        return key
    }
}
