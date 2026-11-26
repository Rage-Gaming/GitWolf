using System.Diagnostics;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

public sealed partial class DiffView : UserControl
{
    /// <summary>Advance width of 13px Consolas.</summary>
    private const double CharWidth = 7.15;
    private const double GutterWidth = 112;

    private double _rowWidth;
    private FileDiff? _diff;
    private string _path = "";
    private Dictionary<int, List<SyntaxToken>> _tokens = [];

    public DiffView()
    {
        InitializeComponent();
        // Syntax colours differ between light and dark.
        ActualThemeChanged += (_, _) => Rebind();
        // Rows fill at least the visible width, which isn't known until the list is laid out.
        Lines.SizeChanged += (_, e) =>
        {
            if (e.NewSize.Width != e.PreviousSize.Width) Repaint();
        };
    }

    private bool _split;

    /// <summary>Raised when the user picks the other layout, so it can be remembered.</summary>
    internal event Action<bool>? LayoutChanged;

    private bool _syntax = true;

    /// <summary>The syntax highlighting setting.</summary>
    internal bool SyntaxEnabled
    {
        get => _syntax;
        set
        {
            if (_syntax == value) return;
            _syntax = value;
            _tokens = [];
            Repaint();
            if (value && _diff is { } diff) _ = HighlightAsync(diff, _path);
        }
    }

    internal bool IsSplit
    {
        get => _split;
        set
        {
            _split = value;
            Rebind();
        }
    }

    internal void Show(RepositoryStore store)
    {
        var diff = store.Diff;
        var path = store.SelectedTarget?.Path ?? "";
        var slash = path.LastIndexOf('/');
        Folder.Text = path[..(slash + 1)];
        FileName.Text = path[(slash + 1)..] + (diff?.IsTruncated == true ? "  (truncated)" : "");
        Header.Visibility = path.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        var message = store.SelectedTarget is null ? "Select a file to see its changes"
            : diff is null ? ""
            : diff.IsBinary ? "Binary file"
            : diff.Lines.Count == 0 ? "No textual changes"
            : "";
        Empty.Text = message;

        var shown = message.Length == 0 ? diff : null;
        Tools.Visibility = shown is null ? Visibility.Collapsed : Visibility.Visible;
        if (ReferenceEquals(_diff, shown))
        {
            ShowLayout();
            return;
        }
        _diff = shown;
        _path = path;
        _tokens = [];
        Added.Text = $"+{shown?.Lines.Count(l => l.Kind == DiffLineKind.Addition) ?? 0}";
        Removed.Text = $"\u2212{shown?.Lines.Count(l => l.Kind == DiffLineKind.Deletion) ?? 0}";
        // Every row gets the width of the longest line, so horizontal scrolling stays stable.
        var longest = shown is { Lines.Count: > 0 } ? shown.Lines.Max(DiffRowView.DisplayLength) : 0;
        _rowWidth = GutterWidth + longest * CharWidth;
        Rebind();
        if (shown is not null && _syntax) _ = HighlightAsync(shown, path);
    }

    private void OnLayout(object sender, RoutedEventArgs e)
    {
        var split = ReferenceEquals(sender, SplitButton);
        if (split == _split) return;
        IsSplit = split;
        LayoutChanged?.Invoke(split);
    }

    private void ShowLayout()
    {
        Lines.Visibility = _diff is not null && !_split ? Visibility.Visible : Visibility.Collapsed;
        Split.Visibility = _diff is not null && _split ? Visibility.Visible : Visibility.Collapsed;
        UnifiedSelected.Visibility = _split ? Visibility.Collapsed : Visibility.Visible;
        SplitSelected.Visibility = _split ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>Tokenises off the UI thread; a result for a diff no longer shown is dropped.</summary>
    private async Task HighlightAsync(FileDiff diff, string path)
    {
        try
        {
            var tokens = await Task.Run(() => SyntaxHighlighter.Tokens(diff, path));
            if (!_syntax || !ReferenceEquals(_diff, diff) || path != _path || tokens.Count == 0) return;
            _tokens = tokens;
            Repaint();
        }
        catch (Exception e)
        {
            // Colouring is optional; the plain diff stays visible.
            Trace.TraceWarning($"Syntax highlighting failed: {e.GetType().Name}");
        }
    }

    /// <summary>Redraws only the rows that exist; later rows are drawn as they appear.</summary>
    private void Repaint()
    {
        if (Lines.ItemsPanelRoot is ItemsStackPanel unified)
            foreach (var child in unified.Children)
                if (child is ListViewItem { ContentTemplateRoot: DiffRowView view } item
                    && Lines.ItemFromContainer(item) is DiffLine line)
                    Render(view, line);
        if (Split.ItemsPanelRoot is ItemsStackPanel split)
            foreach (var child in split.Children)
                if (child is ListViewItem { ContentTemplateRoot: SplitRowView view } item
                    && Split.ItemFromContainer(item) is SplitRow row)
                    view.Show(row, _tokens);
    }

    /// <summary>Only the visible layout holds items, so the hidden one costs nothing.</summary>
    private void Rebind()
    {
        ShowLayout();
        Lines.ItemsSource = null;
        Split.ItemsSource = null;
        if (_diff is null) return;
        if (_split) Split.ItemsSource = SideBySide.Rows(_diff);
        else Lines.ItemsSource = _diff.Lines;
    }

    private void OnSplitRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.ItemContainer.ContentTemplateRoot is SplitRowView view && args.Item is SplitRow row)
            view.Show(row, _tokens);
    }

    private void Render(DiffRowView view, DiffLine line) =>
        view.Show(line, _tokens.GetValueOrDefault(line.Id), Math.Max(_rowWidth, Lines.ActualWidth - 16));

    private void OnRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.ItemContainer.ContentTemplateRoot is DiffRowView view && args.Item is DiffLine line)
            Render(view, line);
    }
}
