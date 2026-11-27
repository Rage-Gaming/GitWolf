using System.Diagnostics;
using GitWolf.App.Views;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace GitWolf.App.Services;

/// <summary>Shows authors' profile pictures from the cache. Used on the UI thread only.</summary>
internal static class Avatars
{
    private static readonly AvatarCache Cache = new(System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "GitWolf", "avatars"));
    /// <summary>One per picture, shared by every place showing it, so a new picture appears in all of them.</summary>
    private static readonly Dictionary<Uri, ImageBrush> Brushes = [];
    private static bool _enabled = true;

    /// <summary>Turning pictures off also deletes the saved ones.</summary>
    public static bool Enabled
    {
        get => _enabled;
        set
        {
            _enabled = value;
            if (value) return;
            Brushes.Clear();
            Cache.Clear();
        }
    }

    /// <summary>Raised when rows should redraw: authors were learnt, or pictures switched on or off.</summary>
    public static event Action? Changed;

    public static void Refresh() => Changed?.Invoke();

    /// <summary>Saves what has not been written yet, before the app closes.</summary>
    public static void Save() => Cache.Flush();

    /// <summary>Looks up a repository's authors when the cache says it is worth asking.</summary>
    public static async Task LoadAsync(RemoteLocation? location, IReadOnlyList<Commit> commits)
    {
        if (!Enabled || location is null || commits.Count == 0) return;
        try
        {
            var learnt = await Task.Run(async () => Cache.CanAsk(location)
                && await Cache.LookUpAsync(location, commits.Select(c => c.AuthorEmail).Distinct()));
            if (learnt) Changed?.Invoke();
        }
        catch (Exception e)
        {
            // Fire-and-forget: initials stay.
            Trace.TraceWarning($"Showing profile pictures failed: {e.GetType().Name}");
        }
    }

    /// <summary>
    /// Covers the initials with the author's picture: the saved one at once, then a newer one if it has
    /// changed. Until there is one, the brush is empty and the initials show through.
    /// </summary>
    public static void Show(Ellipse target, string email)
    {
        var address = Enabled ? Cache.PictureFor(email) : null;
        if (address is null)
        {
            target.Fill = null;
            target.Visibility = Visibility.Collapsed;
            return;
        }
        if (!Brushes.TryGetValue(address, out var brush))
        {
            Brushes[address] = brush = new ImageBrush { Stretch = Stretch.UniformToFill };
            Load(brush, address);
        }
        target.Fill = brush;
        target.Visibility = Visibility.Visible;
        if (Cache.IsStale(address)) _ = RefreshAsync(brush, address);
    }

    private static async Task RefreshAsync(ImageBrush brush, Uri address)
    {
        try
        {
            if (await Cache.RefreshAsync(address) && Enabled) Load(brush, address);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Refreshing a profile picture failed: {e.GetType().Name}");
        }
    }

    private static void Load(ImageBrush brush, Uri address)
    {
        if (Cache.CachedFile(address) is not { } file) return;
        var image = new BitmapImage { DecodePixelWidth = 96 };
        // A file that cannot be decoded is downloaded again later.
        image.ImageFailed += (_, _) => Cache.Discard(address);
        image.UriSource = new Uri(file);
        brush.ImageSource = image;
    }
}
