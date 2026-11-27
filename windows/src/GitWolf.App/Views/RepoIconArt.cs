using GitWolf.Core;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.UI;

namespace GitWolf.App.Views;

/// <summary>How Windows draws tile symbols, colours and imported images.</summary>
internal static class RepoIconArt
{
    // Segoe MDL2 Assets, which Windows 10 and 11 both have.
    private static readonly Dictionary<string, string> Glyphs = new()
    {
        ["chevron.left.forwardslash.chevron.right"] = "", ["terminal"] = "", ["hammer"] = "",
        ["wrench.and.screwdriver"] = "", ["cpu"] = "", ["memorychip"] = "",
        ["server.rack"] = "", ["externaldrive"] = "", ["network"] = "",
        ["app"] = "", ["macwindow"] = "", ["iphone"] = "", ["laptopcomputer"] = "",
        ["globe"] = "", ["doc.text"] = "", ["book"] = "", ["paintbrush"] = "",
        ["photo"] = "",
        ["star"] = "", ["heart"] = "", ["flame"] = "", ["bolt"] = "", ["leaf"] = "",
        ["moon"] = "", ["sun.max"] = "", ["cloud"] = "", ["drop"] = "",
        ["shippingbox"] = "", ["cube"] = "", ["gearshape"] = "", ["key"] = "",
        ["lock"] = "", ["flag"] = "", ["tag"] = "", ["folder"] = "",
        ["briefcase"] = "",
        ["gamecontroller"] = "", ["music.note"] = "", ["camera"] = "", ["film"] = "",
        ["airplane"] = "", ["car"] = "", ["paperplane"] = "", ["sparkles"] = "",
        ["lightbulb"] = "",
    };

    private static readonly FontFamily Symbols = new("Segoe MDL2 Assets");

    /// <summary>Null for a name this platform has no picture for.</summary>
    public static FontIcon? Symbol(string name, double size) => Glyphs.TryGetValue(name, out var glyph)
        ? new FontIcon { Glyph = glyph, FontFamily = Symbols, FontSize = size }
        : null;

    private static readonly Dictionary<RepoTint, SolidColorBrush> Brushes = [];

    public static SolidColorBrush Colour(RepoTint tint)
    {
        if (Brushes.TryGetValue(tint, out var brush)) return brush;
        var rgb = tint switch
        {
            RepoTint.Red => 0xE5534Bu,
            RepoTint.Orange => 0xD9822Bu,
            RepoTint.Yellow => 0xC99A12u,
            RepoTint.Green => 0x2EA043u,
            RepoTint.Teal => 0x14A3A3u,
            RepoTint.Blue => 0x3B82F6u,
            RepoTint.Purple => 0x8B5CF6u,
            RepoTint.Pink => 0xDB2777u,
            _ => 0x7D8590u,
        };
        return Brushes[tint] = new SolidColorBrush(
            Color.FromArgb(255, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb));
    }

    private static readonly Dictionary<string, ImageBrush> Images = [];

    /// <summary>Loaded once per file; null when the file has gone.</summary>
    public static ImageBrush? Image(RepoIconStore store, string name)
    {
        if (Images.TryGetValue(name, out var brush)) return brush;
        var path = store.ImagePath(name);
        if (!File.Exists(path)) return null;
        return Images[name] = new ImageBrush
        {
            ImageSource = new BitmapImage(new Uri(path)), Stretch = Stretch.UniformToFill,
        };
    }
}
