using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

/// <summary>One side-by-side row. Long lines wrap so both halves always fit the panel.</summary>
public sealed partial class SplitRowView : UserControl
{
    private LineSelector? _left;
    private LineSelector? _right;
    private HunkActions? _actions;

    public SplitRowView() => InitializeComponent();

    internal void Show(SplitRow row, IReadOnlyDictionary<int, List<SyntaxToken>> tokens, DiffStaging? staging)
    {
        var dark = ActualTheme != ElementTheme.Light;
        var header = row.Header is not null;
        Left.Visibility = Right.Visibility = header ? Visibility.Collapsed : Visibility.Visible;
        Hunk.Visibility = header ? Visibility.Visible : Visibility.Collapsed;
        Root.MinHeight = header && staging is not null ? 28 : 20;
        LeftSelect.Width = RightSelect.Width = new GridLength(staging is null ? 0 : LineSelector.ColumnWidth);
        HunkActions.Place(Root, ref _actions, header ? staging : null, row.Header?.HunkIndex ?? 0);
        if (_actions is not null)
        {
            Grid.SetColumnSpan(_actions, 2);
            _actions.HorizontalAlignment = HorizontalAlignment.Right;
            _actions.Margin = new Thickness(0, 0, 12, 0);
        }
        Hunk.Margin = new Thickness(0, 0, header && staging is not null ? 170 : 0, 0);
        // Context lines sit on both sides; only changes can be selected.
        LineSelector.Place(Left, ref _left, staging, header ? null : row.Left, 0, 2);
        LineSelector.Place(Right, ref _right, staging, header ? null : row.Right, 0, 2);
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
