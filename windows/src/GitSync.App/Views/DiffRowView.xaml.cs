using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace GitSync.App.Views;

public sealed partial class DiffRowView : UserControl
{
    /// <summary>Longer lines are cut for display so one minified file can't stall layout.</summary>
    internal const int MaxColumns = 2000;

    private LineSelector? _selector;
    private HunkActions? _actions;

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

    /// <param name="staging">Null when the diff is read-only.</param>
    /// <param name="visibleWidth">Width of the list, which hunk buttons are lined up with.</param>
    internal void Show(
        DiffLine line, IReadOnlyList<SyntaxToken>? tokens, double width, DiffStaging? staging, double visibleWidth)
    {
        Width = width;
        var header = line.Kind == DiffLineKind.HunkHeader;
        Root.Height = header && staging is not null ? 28 : 20;
        SelectColumn.Width = new GridLength(staging is null ? 0 : LineSelector.ColumnWidth);
        LineSelector.Place(Root, ref _selector, staging, line, 0, 3);
        HunkActions.Place(Root, ref _actions, header ? staging : null, line.HunkIndex);
        Code.MaxWidth = double.PositiveInfinity;
        Code.TextTrimming = TextTrimming.None;
        if (header && staging is not null && _actions is not null)
        {
            // At the right edge of what is visible, however long the longest line is.
            var actionsWidth = HunkActions.WidthFor(staging);
            var visible = Math.Max(visibleWidth - 8, actionsWidth * 2);
            Grid.SetColumnSpan(_actions, 4);
            _actions.HorizontalAlignment = HorizontalAlignment.Left;
            _actions.Margin = new Thickness(visible - actionsWidth, 0, 0, 0);
            Code.MaxWidth = Math.Max(visible - actionsWidth - 120, 80);
            Code.TextTrimming = TextTrimming.CharacterEllipsis;
        }
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
