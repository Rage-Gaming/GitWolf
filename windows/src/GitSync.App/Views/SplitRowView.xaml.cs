using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

/// <summary>One side-by-side row. Long lines wrap so both halves always fit the panel.</summary>
public sealed partial class SplitRowView : UserControl
{
    public SplitRowView() => InitializeComponent();

    internal void Show(SplitRow row, IReadOnlyDictionary<int, List<SyntaxToken>> tokens)
    {
        var dark = ActualTheme != ElementTheme.Light;
        var header = row.Header is not null;
        Left.Visibility = Right.Visibility = header ? Visibility.Collapsed : Visibility.Visible;
        Hunk.Visibility = header ? Visibility.Visible : Visibility.Collapsed;
        if (row.Header is { } hunk)
        {
            DiffRowView.Fill(Hunk, hunk, null, dark, "");
            return;
        }
        Side(Left, LeftNumber, LeftCode, row.Left, row.Left?.OldNumber, tokens, dark);
        Side(Right, RightNumber, RightCode, row.Right, row.Right?.NewNumber, tokens, dark);
    }

    private static void Side(
        Grid panel, TextBlock number, TextBlock code, DiffLine? line, int? lineNumber,
        IReadOnlyDictionary<int, List<SyntaxToken>> tokens, bool dark)
    {
        panel.Background = DiffRowView.LineFill(line);
        number.Text = lineNumber?.ToString() ?? "";
        if (line is null) code.Inlines.Clear();
        else DiffRowView.Fill(code, line, tokens.GetValueOrDefault(line.Id), dark, "");
    }
}
