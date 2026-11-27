using System.Globalization;

namespace GitWolf.Core;

// The two versions of an image file, for previews. Ported from GitRepository.swift.
public sealed partial class GitRepository
{
    private const long ImageLimit = 20_000_000;

    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff", ".heic", ".ico",
    };

    public static bool IsImagePath(string path) => ImageExtensions.Contains(Path.GetExtension(path));

    /// <summary>
    /// File contents on each side of a diff target. Null means absent on that side, or too large to show.
    /// </summary>
    public async Task<(byte[]? Old, byte[]? New)> ImageVersionsAsync(DiffTarget target)
    {
        var old = target.OriginalPath ?? target.Path;
        switch (target.Source.Kind)
        {
            case DiffSourceKind.Unstaged:
            case DiffSourceKind.Conflicted:
                return (await BlobAsync($":0:{old}"), await WorkingFileAsync(target.Path));
            case DiffSourceKind.Staged:
                return (await BlobAsync($"HEAD:{old}"), await BlobAsync($":0:{target.Path}"));
            case DiffSourceKind.Untracked:
                return (null, await WorkingFileAsync(target.Path));
            case DiffSourceKind.Commit:
                var hash = target.Source.CommitHash!;
                var parent = await ParentOrEmptyTreeAsync(hash);
                return (parent == EmptyTree ? null : await BlobAsync($"{parent}:{old}"),
                    await BlobAsync($"{hash}:{target.Path}"));
            case DiffSourceKind.Compare:
                return (await BlobAsync($"{target.Source.BaseHash}:{old}"),
                    await BlobAsync($"{target.Source.CommitHash}:{target.Path}"));
            default:
                throw new ArgumentOutOfRangeException(nameof(target));
        }
    }

    private async Task<byte[]?> BlobAsync(string spec)
    {
        try
        {
            // The size is asked first, so a huge file is never read into memory.
            var size = await Git.RunStringAsync(["cat-file", "-s", Operand(spec)], readOnly: true);
            if (!long.TryParse(size.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var bytes)
                || bytes > ImageLimit)
                return null;
            return await Git.RunAsync(["cat-file", "blob", spec], readOnly: true);
        }
        catch (GitException error) when (error is not UntrustedRepositoryException)
        {
            return null; // The file doesn't exist on that side.
        }
    }

    /// <summary>
    /// A file in the working tree. Links are not followed: one in a repository could point anywhere,
    /// including a network share that would be sent the user's Windows sign-in.
    /// </summary>
    private async Task<byte[]?> WorkingFileAsync(string path)
    {
        var root = Path.GetFullPath(Root);
        var full = Path.GetFullPath(Path.Combine(root, path));
        if (!full.StartsWith(Path.TrimEndingDirectorySeparator(root) + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase))
            return null;
        try
        {
            // Every folder on the way is checked, outermost first, so nothing is looked up through a link.
            var current = root;
            foreach (var part in Path.GetRelativePath(root, full).Split(Path.DirectorySeparatorChar))
            {
                current = Path.Combine(current, part);
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) return null;
            }
            return new FileInfo(full).Length > ImageLimit ? null : await File.ReadAllBytesAsync(full);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
