using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace GitWolf.App.Views;

/// <summary>The bisect and shallow-clone banners. Ported from BisectBanner.swift.</summary>
public sealed partial class ToolBannersView : UserControl
{
    private readonly StackPanel _panel = new();

    public ToolBannersView() => Content = _panel;

    internal void Show(RepositoryStore store)
    {
        _panel.Children.Clear();
        ShowBisect(store);
        if (store.IsShallow)
            Add(Color.FromArgb(255, 0x3B, 0x82, 0xF6), "Shallow clone",
                "Older history isn’t downloaded.", store,
                ("Fetch full history", () => _ = store.UnshallowAsync()));
    }

    private void ShowBisect(RepositoryStore store)
    {
        var state = store.Bisect;
        var purple = Color.FromArgb(255, 0x8B, 0x5C, 0xF6);
        if (state.FirstBad is { } culprit)
            Add(purple, $"First bad commit: {Short(culprit)}", "Bisect narrowed it down to this commit.", store,
                ("Show commit", () => store.Reveal(culprit)),
                ("Finish", () => _ = store.StopBisectAsync()));
        else if (state.IsActive)
            Add(purple, "Bisecting",
                (state.Progress is { } progress ? progress + ". " : "") + "Build and run it, then mark it Good or Bad.",
                store,
                ("Skip", () => _ = store.BisectMarkCurrentAsync(BisectMark.Skip)),
                ("Bad", () => _ = store.BisectMarkCurrentAsync(BisectMark.Bad)),
                ("Good", () => _ = store.BisectMarkCurrentAsync(BisectMark.Good)),
                ("Stop", () => _ = store.StopBisectAsync()));
        else if (store.BisectGood is { } good)
            Add(purple, "Bisect: pick a bad commit",
                $"{Short(good)} is good. Right-click a commit that has the bug and choose “Bisect: this commit is bad”.",
                store, ("Cancel", () => _ = store.StopBisectAsync()));
        else if (store.BisectBad is { } bad)
            Add(purple, "Bisect: pick a good commit",
                $"{Short(bad)} is bad. Right-click an older commit that worked and choose “Bisect: this commit is good”.",
                store, ("Cancel", () => _ = store.StopBisectAsync()));
    }

    private static string Short(string hash) => hash[..Math.Min(7, hash.Length)];

    private void Add(
        Color color, string title, string detail, RepositoryStore store, params (string Text, Action Run)[] actions)
    {
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        text.Children.Add(new TextBlock
        {
            Text = detail, FontSize = 12, Opacity = 0.75, TextWrapping = TextWrapping.Wrap,
        });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var (label, run) in actions)
        {
            var button = new Button { Content = label, IsEnabled = !store.IsBusy };
            button.Click += (_, _) => run();
            buttons.Children.Add(button);
        }
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
        _panel.Children.Add(new Border
        {
            Child = grid, Padding = new Thickness(14, 8, 14, 8), CornerRadius = new CornerRadius(12),
            Margin = new Thickness(0, 0, 10, 8), BorderThickness = new Thickness(1),
            Background = new SolidColorBrush(Color.FromArgb(32, color.R, color.G, color.B)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(90, color.R, color.G, color.B)),
        });
    }
}
