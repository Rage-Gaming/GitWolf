using System.Diagnostics;
using GitWolf.App.Views;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;

namespace GitWolf.App.Services;

/// <summary>The profile pictures known this session. Used on the UI thread only.</summary>
internal static class Avatars
{
    private static readonly Dictionary<string, Uri> Known = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Dictionary<Uri, ImageBrush> Brushes = [];
    private static readonly HashSet<string> Asked = new(StringComparer.OrdinalIgnoreCase);

    public static bool Enabled { get; set; } = true;

    /// <summary>Raised when pictures were learnt or switched on or off, so rows can redraw.</summary>
    public static event Action? Changed;

    public static void Refresh() => Changed?.Invoke();

    /// <summary>Looks up a repository's authors, once per session.</summary>
    public static async Task LoadAsync(RemoteLocation? location)
    {
        if (!Enabled || location is null || !AuthorAvatars.CanLookUp(location) || !Asked.Add(location.Path)) return;
        try
        {
            var found = await Task.Run(() => AuthorAvatars.FetchAsync(location));
            if (found.Count == 0) return;
            foreach (var (email, picture) in found) Known[email] = picture;
            Changed?.Invoke();
        }
        catch (Exception e)
        {
            // Fire-and-forget: initials stay.
            Trace.TraceWarning($"Showing profile pictures failed: {e.GetType().Name}");
        }
    }

    /// <summary>
    /// Covers the initials with the author's picture. Until it has downloaded, or if it can't be, the
    /// brush is transparent and the initials show through.
    /// </summary>
    public static void Show(Ellipse target, string email)
    {
        var address = !Enabled ? null
            : Known.TryGetValue(email, out var known) ? known : AuthorAvatars.FromEmail(email);
        if (address is null)
        {
            target.Fill = null;
            target.Visibility = Visibility.Collapsed;
            return;
        }
        if (!Brushes.TryGetValue(address, out var brush))
            Brushes[address] = brush = new ImageBrush
            {
                ImageSource = new BitmapImage(address) { DecodePixelWidth = 96 },
                Stretch = Stretch.UniformToFill,
            };
        target.Fill = brush;
        target.Visibility = Visibility.Visible;
    }
}
