using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;

namespace GitWolf.Core;

/// <summary>
/// Secrets in Windows Credential Manager (generic credentials, kept on this machine only), the Windows
/// counterpart of the macOS Keychain. One credential holds at most 2560 bytes, which OAuth token pairs
/// can exceed, so longer secrets are split over numbered entries.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class WindowsCredentialStore(
    string service = "GitWolf Provider Accounts", string? legacyService = "GitSync Provider Accounts") : ISecretStore
{
    private const int ChunkBytes = 2048;
    private const int MaxChunks = 32;
    private const uint Generic = 1;
    private const uint LocalMachine = 2;
    private const int NotFound = 1168;

    /// <summary>Where secrets saved before the rename from GitSync are kept.</summary>
    private readonly WindowsCredentialStore? _legacy =
        legacyService is null ? null : new WindowsCredentialStore(legacyService, null);

    public void Save(string account, string secret)
    {
        var bytes = Encoding.UTF8.GetBytes(secret);
        var count = Math.Max(1, (bytes.Length + ChunkBytes - 1) / ChunkBytes);
        if (count > MaxChunks) throw new SecretStoreException("That secret is too long to store.");
        DeleteOwn(account);
        for (var i = 0; i < count; i++)
        {
            var chunk = bytes.AsSpan(i * ChunkBytes, Math.Min(ChunkBytes, bytes.Length - i * ChunkBytes)).ToArray();
            // The first entry records how many there are.
            if (!Write(Target(account, i), i == 0 ? count.ToString() : account, chunk))
            {
                var error = new Win32Exception(Marshal.GetLastWin32Error()).Message;
                DeleteOwn(account);
                throw new SecretStoreException($"Windows Credential Manager couldn’t save the secret: {error}");
            }
        }
    }

    /// <summary>A secret saved under the old name is moved to the new one the first time it is read.</summary>
    public string? Read(string account)
    {
        if (ReadOwn(account) is { } secret) return secret;
        if (_legacy?.ReadOwn(account) is not { } old) return null;
        try
        {
            Save(account, old);
            _legacy.DeleteOwn(account);
        }
        catch (SecretStoreException e)
        {
            // The old entry stays, so the next read tries again.
            System.Diagnostics.Trace.TraceWarning($"Moving a saved credential failed: {e.GetType().Name}");
        }
        return old;
    }

    /// <summary>Removes the secret under both names, so signing out leaves nothing behind.</summary>
    public void Delete(string account)
    {
        DeleteOwn(account);
        _legacy?.DeleteOwn(account);
    }

    private string? ReadOwn(string account)
    {
        if (ReadEntry(Target(account, 0)) is not { } first || !int.TryParse(first.User, out var count)
            || count is < 1 or > MaxChunks) return null;
        var bytes = new List<byte>(first.Blob);
        for (var i = 1; i < count; i++)
        {
            if (ReadEntry(Target(account, i)) is not { } next) return null;
            bytes.AddRange(next.Blob);
        }
        return Encoding.UTF8.GetString(bytes.ToArray());
    }

    private void DeleteOwn(string account)
    {
        for (var i = 0; i < MaxChunks; i++)
        {
            if (CredDelete(Target(account, i), Generic, 0)) continue;
            var error = Marshal.GetLastWin32Error();
            if (error != NotFound)
                System.Diagnostics.Trace.TraceWarning($"Deleting a credential failed with code {error}.");
            return;
        }
    }

    private string Target(string account, int index) => index == 0 ? $"{service}/{account}" : $"{service}/{account}#{index}";

    private static bool Write(string target, string user, byte[] blob)
    {
        var memory = Marshal.AllocHGlobal(Math.Max(blob.Length, 1));
        try
        {
            Marshal.Copy(blob, 0, memory, blob.Length);
            var credential = new Credential
            {
                Type = Generic, TargetName = target, UserName = user, Persist = LocalMachine,
                CredentialBlobSize = (uint)blob.Length, CredentialBlob = memory,
            };
            return CredWrite(ref credential, 0);
        }
        finally
        {
            // Don't leave the secret in freed memory.
            for (var i = 0; i < blob.Length; i++) Marshal.WriteByte(memory, i, 0);
            Marshal.FreeHGlobal(memory);
        }
    }

    private static (string User, byte[] Blob)? ReadEntry(string target)
    {
        if (!CredRead(target, Generic, 0, out var pointer)) return null;
        try
        {
            var credential = Marshal.PtrToStructure<Credential>(pointer);
            var blob = new byte[credential.CredentialBlobSize];
            if (blob.Length > 0) Marshal.Copy(credential.CredentialBlob, blob, 0, blob.Length);
            return (credential.UserName ?? "", blob);
        }
        finally
        {
            CredFree(pointer);
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Credential
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredWrite(ref Credential credential, uint flags);

    [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
