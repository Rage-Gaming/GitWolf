using Org.BouncyCastle.Math.EC.Rfc8032;

namespace GitWolf.Core;

/// <summary>
/// Ed25519 signatures over an update archive's bytes, with keys in base64 as macOS writes them: a 32 byte
/// seed for the private key, 32 bytes for the public one. Ported from UpdateSigning.swift.
/// </summary>
public static class UpdateSigning
{
    public static string PublicKey(string privateKey)
    {
        var key = new byte[Ed25519.PublicKeySize];
        Ed25519.GeneratePublicKey(Seed(privateKey), 0, key, 0);
        return Convert.ToBase64String(key);
    }

    public static string Sign(byte[] data, string privateKey)
    {
        var signature = new byte[Ed25519.SignatureSize];
        Ed25519.Sign(Seed(privateKey), 0, data, 0, data.Length, signature, 0);
        return Convert.ToBase64String(signature);
    }

    /// <summary>False for a wrong signature and for a signature or key that isn't well formed.</summary>
    public static bool Verify(byte[] data, string signature, string publicKey) =>
        Decode(signature, Ed25519.SignatureSize) is { } s && Decode(publicKey, Ed25519.PublicKeySize) is { } k
        && Ed25519.Verify(s, 0, k, 0, data, 0, data.Length);

    /// <summary>The message never repeats the key.</summary>
    private static byte[] Seed(string text) => Decode(text, Ed25519.SecretKeySize)
        ?? throw new FormatException("The private key must be 32 bytes in base64.");

    private static byte[]? Decode(string text, int size)
    {
        var buffer = new byte[size + 3];
        return Convert.TryFromBase64String(text.Trim(), buffer, out var length) && length == size
            ? buffer[..size] : null;
    }
}
