using GitWolf.App.Services;
using GitWolf.Store;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Views;

/// <summary>
/// Shown while a merge, rebase, cherry-pick or revert is waiting: what is happening, what is left to
/// resolve, and the ways out. Ported from OperationBanner.swift.
/// </summary>
public sealed partial class OperationBannerView : UserControl
{
    private readonly TextBlock _title = new() { FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    private readonly TextBlock _detail = new() { FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap };
    private readonly Button _conflicts = new() { Content = "Show conflicts" };
    private readonly Button _skip = new() { Content = "Skip" };
    private readonly Button _abort = new() { Content = "Abort" };
    private readonly Button _continue = new() { Content = "Continue" };
    private RepositoryStore? _store;

    public OperationBannerView()
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Children = { _title, _detail } };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children = { _conflicts, _skip, _abort, _continue },
        };
        Grid.SetColumn(buttons, 1);
        var grid = new Grid
        {
            ColumnSpacing = 12,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children = { text, buttons },
        };
        var orange = Colors.Orange;
        Content = new Border
        {
            Child = grid, Padding = new Thickness(14, 8, 14, 8), CornerRadius = new CornerRadius(12),
            BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(32, orange.R, orange.G, orange.B)),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(90, orange.R, orange.G, orange.B)),
        };
        _continue.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        ToolTipService.SetToolTip(_skip, "Drop the commit that is being applied and move on");

        _conflicts.Click += (_, _) => { if (_store is { } s) s.Mode = StoreMode.Changes; };
        _skip.Click += (_, _) => _ = _store?.SkipOperationAsync();
        _continue.Click += (_, _) => _ = _store?.ContinueOperationAsync();
        _abort.Click += (_, _) =>
        {
            if (_store is { Operation: { } operation } s) _ = Dialogs.AbortAsync(XamlRoot, s, operation);
        };
    }

    internal void Show(RepositoryStore store)
    {
        _store = store;
        var operation = store.Operation;
        Visibility = operation is null ? Visibility.Collapsed : Visibility.Visible;
        if (operation is null) return;
        var conflicts = store.Status.Conflicted.Count;
        _title.Text = operation.Title;
        _detail.Text = conflicts == 0
            ? "No conflicts left. Continue to finish."
            : $"{conflicts} conflicted file{(conflicts == 1 ? "" : "s")} to resolve, then continue.";
        _conflicts.Visibility = conflicts > 0 ? Visibility.Visible : Visibility.Collapsed;
        _skip.Visibility = operation.CanSkip ? Visibility.Visible : Visibility.Collapsed;
        _skip.IsEnabled = _abort.IsEnabled = !store.IsBusy;
        _continue.IsEnabled = !store.IsBusy && conflicts == 0;
    }
}
