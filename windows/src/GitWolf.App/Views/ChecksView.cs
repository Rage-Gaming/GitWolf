using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace GitWolf.App.Views;

/// <summary>
/// CI results of a commit: a summary that expands into the checks. Hidden when there are none. Ported
/// from ChecksSection.swift.
/// </summary>
public sealed class ChecksView : UserControl
{
    private readonly Expander _expander = new()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
    };
    private CiStatus? _shown;

    public ChecksView()
    {
        Content = _expander;
        HorizontalContentAlignment = HorizontalAlignment.Stretch;
        Visibility = Visibility.Collapsed;
    }

    internal void Show(CiStatus? status)
    {
        Visibility = status is { IsEmpty: false } ? Visibility.Visible : Visibility.Collapsed;
        if (status is null || status.IsEmpty || ReferenceEquals(status, _shown)) return;
        _shown = status;
        _expander.IsExpanded = false;
        var overall = status.Overall ?? CheckState.Neutral;
        _expander.Header = Ui.Row(8, Icon(overall), Ui.Text(status.Summary, 12.5, bold: true));
        AutomationProperties.SetName(_expander, status.Summary);

        var list = new StackPanel { Spacing = 4 };
        foreach (var check in status.Checks)
        {
            var row = new Grid
            {
                ColumnSpacing = 8,
                ColumnDefinitions =
                {
                    new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition(),
                    new ColumnDefinition { Width = GridLength.Auto },
                },
            };
            var icon = Icon(check.State);
            var name = Ui.Text(check.Name, 12.5, wrap: false);
            name.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(name, 1);
            row.Children.Add(icon);
            row.Children.Add(name);
            if (check.Url is { } url)
            {
                var details = new HyperlinkButton { Content = "Details", FontSize = 12, Padding = new Thickness(4, 0, 4, 0) };
                ToolTipService.SetToolTip(details, url.AbsoluteUri);
                details.Click += (_, _) => _ = Launcher.LaunchUriAsync(url);
                Grid.SetColumn(details, 2);
                row.Children.Add(details);
            }
            list.Children.Add(row);
        }
        _expander.Content = new ScrollViewer { Content = list, MaxHeight = 140 };
    }

    private static FontIcon Icon(CheckState state) => new()
    {
        Glyph = Ui.CheckGlyph(state), FontSize = 12, Foreground = Ui.CheckBrush(state),
        VerticalAlignment = VerticalAlignment.Center,
    };
}
