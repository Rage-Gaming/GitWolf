using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;

namespace GitSync.App.Views;

internal sealed record PaletteItem(Icons.Shape Icon, string Title, string Subtitle, Action Run);

/// <summary>Ctrl+K: jump between repositories and branches, or run an action. From CommandPalette.swift.</summary>
public sealed partial class CommandPaletteView : UserControl
{
    private IReadOnlyList<PaletteItem> _all = [];

    public CommandPaletteView() => InitializeComponent();

    internal void Open(IReadOnlyList<PaletteItem> items)
    {
        _all = items;
        Visibility = Visibility.Visible;
        Query.Text = "";
        Filter();
        // The box can only take focus once it is visible.
        DispatcherQueue.TryEnqueue(() => Query.Focus(FocusState.Programmatic));
    }

    private void Close()
    {
        Visibility = Visibility.Collapsed;
        Results.ItemsSource = null;
        _all = [];
    }

    private void Filter()
    {
        var query = Query.Text.Trim();
        var matches = query.Length == 0 ? _all : _all
            .Where(i => $"{i.Title} {i.Subtitle}".Contains(query, StringComparison.CurrentCultureIgnoreCase)).ToList();
        Results.ItemsSource = matches;
        Results.SelectedIndex = matches.Count > 0 ? 0 : -1;
    }

    private void Run(PaletteItem item)
    {
        Close();
        item.Run();
    }

    private void OnQuery(object sender, TextChangedEventArgs e) => Filter();

    private void OnKey(object sender, KeyRoutedEventArgs e)
    {
        var count = Results.Items.Count;
        switch (e.Key)
        {
            case VirtualKey.Down or VirtualKey.Up when count > 0:
                var step = e.Key == VirtualKey.Down ? 1 : -1;
                Results.SelectedIndex = Math.Clamp(Results.SelectedIndex + step, 0, count - 1);
                Results.ScrollIntoView(Results.SelectedItem);
                break;
            case VirtualKey.Enter when Results.SelectedItem is PaletteItem item:
                Run(item);
                break;
            case VirtualKey.Escape:
                Close();
                break;
            default:
                return;
        }
        e.Handled = true;
    }

    private void OnClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is PaletteItem item) Run(item);
    }

    private void OnBackdrop(object sender, TappedRoutedEventArgs e) => Close();

    private void OnRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue || args.Item is not PaletteItem item
            || args.ItemContainer.ContentTemplateRoot is not Grid { Children: [ContentPresenter icon, TextBlock title, TextBlock subtitle] })
            return;
        icon.Content = Icons.Create(item.Icon);
        title.Text = item.Title;
        subtitle.Text = item.Subtitle;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(args.ItemContainer, item.Title);
    }
}
