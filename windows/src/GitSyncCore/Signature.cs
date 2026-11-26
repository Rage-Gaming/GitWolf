namespace GitSync.Core;

public enum SignatureState
{
    Good,
    /// <summary>Valid signature, but the key's trust is unknown.</summary>
    GoodUnknownTrust,
    Bad,
    ExpiredSignature,
    ExpiredKey,
    Revoked,
    /// <summary>Signed, but it couldn't be checked.</summary>
    Unverifiable,
}

/// <summary>What git reports about a commit's signature.</summary>
public sealed record CommitSignature(string Format, SignatureState State, string Signer, string Key)
{
    public string Title => State switch
    {
        SignatureState.Good => $"Verified {Format} signature",
        SignatureState.GoodUnknownTrust => $"Valid {Format} signature, key not trusted",
        SignatureState.Bad => $"Bad {Format} signature",
        SignatureState.ExpiredSignature => $"Expired {Format} signature",
        SignatureState.ExpiredKey => "Signed with an expired key",
        SignatureState.Revoked => "Signed with a revoked key",
        _ => $"{Format} signature can’t be verified",
    };
}

public sealed partial class GitRepository
{
    /// <summary>
    /// The signature on a commit, or null when it is unsigned. Only signed commits are verified, so
    /// ordinary history stays cheap.
    /// </summary>
    public async Task<CommitSignature?> SignatureAsync(string hash)
    {
        var raw = await Git.RunStringAsync(["cat-file", "commit", Operand(hash)], readOnly: true);
        // Only the headers: a message may quote a signature.
        var end = raw.IndexOf("\n\n", StringComparison.Ordinal);
        var headers = end < 0 ? raw : raw[..end];
        var format = headers.Contains("-----BEGIN SSH SIGNATURE-----") ? "SSH"
            : headers.Contains("-----BEGIN PGP ") ? "GPG"
            : headers.Contains("-----BEGIN SIGNED MESSAGE-----") ? "X.509" : null;
        if (format is null) return null;
        // Checking runs a program, and the repository's own configuration must not choose it.
        if (await RepositoryChoosesVerifierAsync())
            return new CommitSignature(format, SignatureState.Unverifiable, "", "");

        var output = await Git.RunStringAsync(["log", "-1", "--format=%G?%x1f%GS%x1f%GK", hash, "--"], readOnly: true);
        var f = output.Trim('\r', '\n').Split('\u001f');
        var state = f[0] switch
        {
            "G" => SignatureState.Good,
            "U" => SignatureState.GoodUnknownTrust,
            "B" => SignatureState.Bad,
            "X" => SignatureState.ExpiredSignature,
            "Y" => SignatureState.ExpiredKey,
            "R" => SignatureState.Revoked,
            _ => SignatureState.Unverifiable,
        };
        return new CommitSignature(format, state, f.Length > 1 ? f[1] : "", f.Length > 2 ? f[2] : "");
    }

    private async Task<bool> RepositoryChoosesVerifierAsync()
    {
        try
        {
            var output = await Git.RunStringAsync(
                ["config", "--show-scope", "--includes", "--get-regexp", @"^gpg\..*program$"], readOnly: true);
            return output.Split('\n').Any(l =>
                l.StartsWith("local", StringComparison.Ordinal) || l.StartsWith("worktree", StringComparison.Ordinal));
        }
        catch (GitException error) when (error.ExitCode == 1)
        {
            return false; // Nothing is set.
        }
    }
}
