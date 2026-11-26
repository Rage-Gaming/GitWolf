using GitSync.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace GitSync.App.Views;

/// <summary>Flat colours shared by rows (docs/DESIGN.md, Theme in Components.swift). UI thread only.</summary>
internal static class Palette
{
    private static Color Rgb(uint v, byte alpha = 255) =>
        Color.FromArgb(alpha, (byte)(v >> 16), (byte)(v >> 8), (byte)v);

    private static SolidColorBrush Brush(uint v, byte alpha = 255) => new(Rgb(v, alpha));

    public static readonly SolidColorBrush Clear = new(Colors.Transparent);
    public static readonly SolidColorBrush Green = Brush(0x2EA043);
    public static readonly SolidColorBrush Orange = Brush(0xD9822B);
    public static readonly SolidColorBrush Red = Brush(0xE5534B);
    public static readonly SolidColorBrush Blue = Brush(0x3B82F6);
    public static readonly SolidColorBrush Teal = Brush(0x14A3A3);
    public static readonly SolidColorBrush Pink = Brush(0xDB2777);

    public static readonly SolidColorBrush AddedLine = Brush(0x2EA043, 0x2E);
    public static readonly SolidColorBrush RemovedLine = Brush(0xE5534B, 0x2E);
    public static readonly SolidColorBrush HunkLine = Brush(0x1F80FF, 0x24);

    private static readonly SolidColorBrush[] Lanes =
    [
        Brush(0x5C85FF), Brush(0xBD61F5), Brush(0xFA669E), Brush(0xFF9E40),
        Brush(0x2EC2B8), Brush(0x4DCC73), Brush(0x8C80FF), Brush(0xF25961),
    ];

    public static SolidColorBrush Lane(int index) => Lanes[index % Lanes.Length];

    public static (string Letter, SolidColorBrush Brush, SolidColorBrush Fill) Status(ChangeKind kind) => kind switch
    {
        ChangeKind.Added => ("A", Green, Tint(Green)),
        ChangeKind.Deleted => ("D", Red, Tint(Red)),
        ChangeKind.Renamed => ("R", Blue, Tint(Blue)),
        ChangeKind.Copied => ("C", Green, Tint(Green)),
        ChangeKind.Untracked => ("U", Teal, Tint(Teal)),
        ChangeKind.Unmerged => ("!", Pink, Tint(Pink)),
        ChangeKind.TypeChanged => ("T", Orange, Tint(Orange)),
        _ => ("M", Orange, Tint(Orange)),
    };

    private static readonly Dictionary<(Color, byte), SolidColorBrush> Tints = [];

    /// <summary>A cached translucent version of a solid colour, 16% by default.</summary>
    public static SolidColorBrush Tint(SolidColorBrush brush, byte alpha = 0x29)
    {
        if (Tints.TryGetValue((brush.Color, alpha), out var tint)) return tint;
        var c = brush.Color;
        return Tints[(c, alpha)] = new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
    }

    private static readonly SolidColorBrush TagRef = Brush(0xE08A2E);
    private static readonly SolidColorBrush RemoteRef = Brush(0xDB32F1);
    private static readonly SolidColorBrush HeadRef = Brush(0x8A8F98);
    private static readonly SolidColorBrush LocalRef = Brush(0x2F8BFF);

    public static SolidColorBrush Ref(RefKind kind) => kind switch
    {
        RefKind.Tag => TagRef,
        RefKind.Remote => RemoteRef,
        RefKind.Head => HeadRef,
        _ => LocalRef,
    };

    /// <summary>Recolours the accent brushes in place, including tints already on screen.</summary>
    public static void SetAccent(Color accent)
    {
        var old = LocalRef.Color;
        if (old == accent) return;
        foreach (var (key, brush) in Tints.Where(t => t.Key.Item1 == old).ToList())
        {
            Tints.Remove(key);
            brush.Color = Color.FromArgb(key.Item2, accent.R, accent.G, accent.B);
            Tints[(accent, key.Item2)] = brush;
        }
        LocalRef.Color = accent;
        HunkLine.Color = Color.FromArgb(HunkLine.Color.A, accent.R, accent.G, accent.B);
    }

    private static readonly Dictionary<int, SolidColorBrush> Avatars = [];

    /// <summary>Stable colour per person: a deterministic hash of the email, never a randomised one.</summary>
    public static SolidColorBrush Avatar(string seed)
    {
        var hash = 5381L;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(seed.ToLowerInvariant())) hash = unchecked(hash * 33 + b);
        var hue = (int)Math.Abs(hash % 360);
        if (Avatars.TryGetValue(hue, out var brush)) return brush;

        // HSB with saturation 0.5 and brightness 0.78.
        const double v = 0.78, s = 0.5;
        byte Channel(int n)
        {
            var k = (n + hue / 60.0) % 6;
            return (byte)Math.Round(255 * (v - v * s * Math.Max(0, Math.Min(Math.Min(k, 4 - k), 1))));
        }
        return Avatars[hue] = new SolidColorBrush(Color.FromArgb(255, Channel(5), Channel(3), Channel(1)));
    }

    private static readonly SolidColorBrush[] DarkSyntax =
        [Brush(0xFF7AB2), Brush(0x5DD8FF), Brush(0xFF8170), Brush(0x7F8C98), Brush(0xD9C97C), Brush(0xB48CFF), Brush(0xFFA14F)];

    private static readonly SolidColorBrush[] LightSyntax =
        [Brush(0xAD3DA4), Brush(0x0B6E99), Brush(0xC41A16), Brush(0x6C7986), Brush(0x1C00CF), Brush(0x4B21B0), Brush(0x9B2393)];

    /// <summary>Indexed in <see cref="SyntaxKind"/> declaration order.</summary>
    public static SolidColorBrush Syntax(SyntaxKind kind, bool dark) => (dark ? DarkSyntax : LightSyntax)[(int)kind];
}
