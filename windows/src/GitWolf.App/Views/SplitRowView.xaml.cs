using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Views;

/// <summary>One side-by-side row. Long lines wrap so both halves always fit the panel.</summary>
public sealed partial class SplitRowView : UserControl
{
    private LineSelector? _left;
    private LineSelector? _right;
    private HunkActions? _actions;
    private Button? _fold;

    public SplitRowView() => InitializeComponent();

    internal void Show(
        SplitRow row, IReadOnlyDictionary<int, List<SyntaxToken>> tokens,
        IReadOnlyDictionary<int, IReadOnlyList<TextSpan>> changes, DiffStaging? staging, Action<DiffLine> unfold)
    {
        var dark = ActualTheme != ElementTheme.Light;
        var header = row.Header is not null;
        var fold = row.Header is { IsFold: true } folded ? folded : null;
        FoldButton.Place(Root, ref _fold, fold, 2, unfold);
        Left.Visibility = Right.Visibility = header ? Visibility.Collapsed : Visibility.Visible;
        Hunk.Visibility = header ? Visibility.Visible : Visibility.Collapsed;
        if (fold is not null) Hunk.Visibility = Visibility.Collapsed;
        var actions = header && fold is null ? staging : null;
        Root.MinHeight = actions is not null ? 28 : 20;
        LeftSelect.Width = RightSelect.Width = new GridLength(staging is null ? 0 : LineSelector.ColumnWidth);
        HunkActions.Place(Root, ref _actions, actions, row.Header?.HunkIndex ?? 0);
        if (_actions is not null)
        {
            Grid.SetColumnSpan(_actions, 2);
            _actions.HorizontalAlignment = HorizontalAlignment.Right;
            _actions.Margin = new Thickness(0, 0, 12, 0);
        }
        Hunk.Margin = new Thickness(0, 0, actions is not null ? HunkActions.WidthFor(actions) : 0, 0);
        // Context lines sit on both sides; only changes can be selected.
        LineSelector.Place(Left, ref _left, staging, header ? null : row.Left, 0, 2);
        LineSelector.Place(Right, ref _right, staging, header ? null : row.Right, 0, 2);
        if (row.Header is { } hunk)
        {
            DiffRowView.Fill(Hunk, hunk, null, dark, "");
            return;
        }
        Side(Left, LeftNumber, LeftCode, row.Left, row.Left?.OldNumber, tokens, changes, dark);
        Side(Right, RightNumber, RightCode, row.Right, row.Right?.NewNumber, tokens, changes, dark);
    }

    private static void Side(
        Grid panel, TextBlock number, TextBlock code, DiffLine? line, int? lineNumber,
        IReadOnlyDictionary<int, List<SyntaxToken>> tokens,
        IReadOnlyDictionary<int, IReadOnlyList<TextSpan>> changes, bool dark)
    {
        panel.Background = DiffRowView.LineFill(line);
        number.Text = lineNumber?.ToString() ?? "";
        if (line is null)
        {
            code.Inlines.Clear();
            code.TextHighlighters.Clear();
        }
        else DiffRowView.Fill(code, line, tokens.GetValueOrDefault(line.Id), dark, "", changes.GetValueOrDefault(line.Id));
    }
}
