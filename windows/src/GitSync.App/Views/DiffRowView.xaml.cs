using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace GitSync.App.Views;

public sealed partial class DiffRowView : UserControl
{
    /// <summary>Longer lines are cut for display so one minified file can't stall layout.</summary>
    internal const int MaxColumns = 2000;

    public DiffRowView() => InitializeComponent();

    private static string Source(DiffLine line) =>
        (line.Kind is DiffLineKind.HunkHeader or DiffLineKind.Note ? line.Raw : line.Text).TrimEnd('\r');

    private static string Sign(DiffLine line) => line.Kind switch
    {
        DiffLineKind.Addition => "+ ",
        DiffLineKind.Deletion => "- ",
        DiffLineKind.Context => "  ",
        _ => "",
    };

    private static string Expand(string text) => text.Replace("\t", "    ");

    /// <summary>Number of characters <see cref="Show"/> will render, for sizing rows.</summary>
    internal static int DisplayLength(DiffLine line)
    {
        var text = Source(line);
        var tabs = text.AsSpan().Count('\t');
        return Math.Min(text.Length + tabs * 3, MaxColumns + 2) + Sign(line).Length;
    }

    internal static Microsoft.UI.Xaml.Media.SolidColorBrush LineFill(DiffLine? line) => line?.Kind switch
    {
        DiffLineKind.Addition => Palette.AddedLine,
        DiffLineKind.Deletion => Palette.RemovedLine,
        DiffLineKind.HunkHeader => Palette.HunkLine,
        _ => Palette.Clear,
    };

    internal void Show(DiffLine line, IReadOnlyList<SyntaxToken>? tokens, double width)
    {
        Width = width;
        Old.Text = line.OldNumber?.ToString() ?? "";
        New.Text = line.NewNumber?.ToString() ?? "";
        Root.Background = LineFill(line);
        Fill(Code, line, tokens, ActualTheme != ElementTheme.Light, Sign(line));
    }

    /// <summary>Writes a line into <paramref name="target"/> with syntax colours.</summary>
    internal static void Fill(TextBlock target, DiffLine line, IReadOnlyList<SyntaxToken>? tokens, bool dark, string prefix)
    {
        var text = Source(line);
        var cut = text.Length > MaxColumns;
        if (cut) text = text[..MaxColumns];

        target.Inlines.Clear();
        if (line.Kind == DiffLineKind.HunkHeader) target.Foreground = Palette.Ref(RefKind.Local);
        else target.ClearValue(TextBlock.ForegroundProperty);

        void Add(string part)
        {
            if (part.Length > 0) target.Inlines.Add(new Run { Text = part });
        }

        Add(prefix);
        var position = 0;
        foreach (var token in tokens ?? [])
        {
            var start = Math.Max(token.Start, position);
            var end = Math.Min(token.End, text.Length);
            if (end <= start) continue;
            Add(Expand(text[position..start]));
            target.Inlines.Add(new Run { Text = Expand(text[start..end]), Foreground = Palette.Syntax(token.Kind, dark) });
            position = end;
        }
        Add(Expand(text[position..]) + (cut ? " \u2026" : ""));
    }
}
