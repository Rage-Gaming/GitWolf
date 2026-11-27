using System.Reflection;
using GitWolf.Core;

namespace GitWolf.App.Services;

/// <summary>What this copy of the app was built as.</summary>
internal static class AppBuild
{
    private static readonly Assembly Assembly = typeof(AppBuild).Assembly;

    public static readonly AppVersion? Version =
        AppVersion.TryParse(Assembly.GetName().Version?.ToString(3), out var version) ? version : null;

    /// <summary>
    /// Set only by the release workflow. Development builds never contact the update server, and would
    /// otherwise replace themselves with a release.
    /// </summary>
    public static readonly bool UpdatesEnabled = Version is not null && Assembly
        .GetCustomAttributes<AssemblyMetadataAttribute>()
        .Any(a => a.Key == "GitWolfUpdates" && a.Value == "true");
}
