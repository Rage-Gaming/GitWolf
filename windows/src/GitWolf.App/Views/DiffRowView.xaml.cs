using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace GitWolf.App.Views;

public sealed partial class DiffRowView : UserControl
{
    /// <summary>Longer lines are cut for display so one minified file can't stall layout.</summary>
    internal const int MaxColumns = 2000;

    private LineSelector? _selector;
    private HunkActions? _actions;
    private Button? _fold;

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
        DiffLineKind.Note when line.IsFold => Palette.HunkLine,
        _ => Palette.Clear,
    };

    /// <param name="staging">Null when the diff is read-only.</param>
    /// <param name="visibleWidth">Width of the list, which hunk buttons are lined up with.</param>
    internal void Show(
        DiffLine line, IReadOnlyList<SyntaxToken>? tokens, double width, DiffStaging? staging, double visibleWidth,
        IReadOnlyList<TextSpan>? changes, Action<DiffLine> unfold)
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
        // A fold's number is how many lines it hides, not a line number.
        New.Text = line.IsFold ? "" : line.NewNumber?.ToString() ?? "";
        Root.Background = LineFill(line);
        Fill(Code, line, tokens, ActualTheme != ElementTheme.Light, Sign(line), changes);
        FoldButton.Place(Root, ref _fold, line.IsFold ? line : null, 4, unfold);
        Code.Opacity = line.IsFold ? 0 : 1;
    }

    /// <summary>Writes a line into <paramref name="target"/> with syntax colours.</summary>
    internal static void Fill(
        TextBlock target, DiffLine line, IReadOnlyList<SyntaxToken>? tokens, bool dark, string prefix,
        IReadOnlyList<TextSpan>? changes = null)
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
        Highlight(target, line, text, prefix.Length, changes);
    }

    /// <summary>Marks the words that differ from the paired line.</summary>
    private static void Highlight(
        TextBlock target, DiffLine line, string text, int prefix, IReadOnlyList<TextSpan>? changes)
    {
        // Rows are reused, so the last line's marks are removed first.
        target.TextHighlighters.Clear();
        if (changes is null) return;
        var marks = new TextHighlighter
        {
            Background = line.Kind == DiffLineKind.Addition ? Palette.AddedWord : Palette.RemovedWord,
        };
        // Offsets move by the sign in front and by each tab drawn as four spaces.
        var (counted, tabs) = (0, 0);
        int Shown(int offset)
        {
            for (; counted < offset; counted++)
                if (text[counted] == '\t') tabs++;
            return prefix + offset + tabs * 3;
        }
        foreach (var span in changes)
        {
            if (span.Start >= text.Length) break;
            var start = Shown(span.Start);
            var end = Shown(Math.Min(span.End, text.Length));
            marks.Ranges.Add(new TextRange { StartIndex = start, Length = end - start });
        }
        if (marks.Ranges.Count == 0) return;
        if (target.Foreground is { } foreground) marks.Foreground = foreground;
        target.TextHighlighters.Add(marks);
    }
}
