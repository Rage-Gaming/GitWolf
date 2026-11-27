using GitWolf.App.Services;
using GitWolf.Core;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;
using Windows.UI.Core;

namespace GitWolf.App.Views;

/// <summary>What diff rows need to offer staging. Absent for read-only diffs.</summary>
/// <param name="Staged">True when showing staged changes, where actions unstage.</param>
/// <param name="Stash">Stashes a hunk; null when this file's hunks can't be stashed.</param>
internal sealed record DiffStaging(
    bool Staged, IReadOnlySet<int> Selection, Action<int, bool> Toggle, Action<int, PatchAction> Hunk,
    Action<int>? Stash = null);

/// <summary>
/// The clickable gutter of a changed line: click to select it, Shift-click for a range. Created only
/// for rows that need it, then reused.
/// </summary>
internal sealed partial class LineSelector : Button
{
    internal const double ColumnWidth = 22;

    private readonly Border _bar = new() { Width = 3, HorizontalAlignment = HorizontalAlignment.Left };
    private readonly Border _circle = new()
    {
        Width = 12, Height = 12, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1.5),
        Margin = new Thickness(6, 4, 0, 0), HorizontalAlignment = HorizontalAlignment.Left,
        VerticalAlignment = VerticalAlignment.Top,
    };
    private DiffStaging? _staging;
    private int _line;

    private LineSelector()
    {
        Style = (Style)Application.Current.Resources["PlainButtonStyle"];
        Padding = new Thickness(0);
        Margin = new Thickness(0);
        MinHeight = MinWidth = 0;
        CornerRadius = new CornerRadius(0);
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Stretch;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        VerticalContentAlignment = VerticalAlignment.Stretch;
        Content = new Grid { Children = { _bar, _circle } };
        Click += (_, _) => _staging?.Toggle(_line, ShiftIsDown());
    }

    /// <summary>Covers <paramref name="span"/> gutter columns of <paramref name="row"/> when the line can be selected.</summary>
    internal static void Place(Grid row, ref LineSelector? selector, DiffStaging? staging, DiffLine? line, int column, int span)
    {
        if (staging is null || line is not { IsChange: true })
        {
            if (selector is not null) selector.Visibility = Visibility.Collapsed;
            return;
        }
        if (selector is null)
        {
            selector = new LineSelector();
            row.Children.Add(selector);
        }
        Grid.SetColumn(selector, column);
        Grid.SetColumnSpan(selector, span);
        selector.Show(staging, line.Id);
    }

    private void Show(DiffStaging staging, int line)
    {
        _staging = staging;
        _line = line;
        Visibility = Visibility.Visible;
        var selected = staging.Selection.Contains(line);
        var accent = Palette.Ref(RefKind.Local);
        _bar.Background = selected ? accent : Palette.Clear;
        _circle.Background = selected ? accent : Palette.Clear;
        _circle.BorderBrush = selected ? accent : Palette.Ref(RefKind.Head);
        _circle.Opacity = selected ? 1 : 0.55;
        var verb = staging.Staged ? "unstage" : "stage";
        AutomationProperties.SetName(this, selected ? $"Line selected to {verb}" : $"Select line to {verb}");
        ToolTipService.SetToolTip(this, $"Select line to {verb} (Shift-click for a range)");
    }

    private static bool ShiftIsDown() =>
        InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift).HasFlag(CoreVirtualKeyStates.Down);
}

/// <summary>Stage, unstage and discard buttons on a hunk header.</summary>
internal sealed partial class HunkActions : StackPanel
{
    private readonly Button _apply;
    private readonly Button _discard;
    private readonly Button _stash;
    private DiffStaging? _staging;
    private int _hunk;

    private HunkActions()
    {
        Orientation = Orientation.Horizontal;
        Spacing = 6;
        VerticalAlignment = VerticalAlignment.Center;
        _apply = new Button();
        _apply.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        Size(_apply);
        _apply.Click += (_, _) => _staging?.Hunk(_hunk, _staging.Staged ? PatchAction.Unstage : PatchAction.Stage);
        _discard = new Button();
        Size(_discard);
        _discard.Content = new FontIcon { Glyph = "\uE7A7", FontSize = 11, Foreground = new SolidColorBrush(Colors.IndianRed) };
        AutomationProperties.SetName(_discard, "Discard hunk");
        ToolTipService.SetToolTip(_discard, "Discard hunk");
        _discard.Click += (_, _) => _staging?.Hunk(_hunk, PatchAction.Discard);
        _stash = new Button { Content = "Stash" };
        Size(_stash);
        AutomationProperties.SetName(_stash, "Stash hunk");
        ToolTipService.SetToolTip(_stash, "Stash only this hunk");
        _stash.Click += (_, _) => _staging?.Stash?.Invoke(_hunk);
        Children.Add(_apply);
        Children.Add(_stash);
        Children.Add(_discard);
    }

    /// <summary>The room a header row keeps for these buttons.</summary>
    internal static double WidthFor(DiffStaging staging) => staging.Stash is null ? 170 : 230;

    private static void Size(Button button)
    {
        button.Height = 22;
        button.MinHeight = 0;
        button.MinWidth = 0;
        button.Padding = new Thickness(10, 0, 10, 1);
        button.CornerRadius = new CornerRadius(11);
        button.FontSize = 11;
        button.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        button.FontFamily = FontFamily.XamlAutoFontFamily;
    }

    internal static void Place(Grid row, ref HunkActions? actions, DiffStaging? staging, int hunk)
    {
        if (staging is null)
        {
            if (actions is not null) actions.Visibility = Visibility.Collapsed;
            return;
        }
        if (actions is null)
        {
            actions = new HunkActions();
            row.Children.Add(actions);
        }
        actions._staging = staging;
        actions._hunk = hunk;
        actions.Visibility = Visibility.Visible;
        actions._apply.Content = staging.Staged ? "Unstage Hunk" : "Stage Hunk";
        actions._discard.Visibility = staging.Staged ? Visibility.Collapsed : Visibility.Visible;
        actions._stash.Visibility = staging.Stash is null ? Visibility.Collapsed : Visibility.Visible;
    }
}
