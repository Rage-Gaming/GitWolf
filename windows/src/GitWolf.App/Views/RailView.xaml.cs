using System.ComponentModel;
using System.Diagnostics;
using GitWolf.App.Services;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace GitWolf.App.Views;

/// <summary>Strip of open repositories with change-count badges. Ported from RepoRail.swift.</summary>
public sealed partial class RailView : UserControl
{
    private readonly Dictionary<RepositoryStore, Tile> _tiles = [];
    private Workspace? _workspace;

    public RailView() => InitializeComponent();

    internal event Action<FrameworkElement>? AddRequested;
    internal event Action? SettingsRequested;
    /// <summary>The user asked to change a repository's icon.</summary>
    internal event Action<RepositoryStore>? IconRequested;
    /// <summary>A picture was dropped on a repository's tile.</summary>
    internal event Action<RepositoryStore, DataPackageView>? ImageDropped;

    internal void Attach(Workspace workspace)
    {
        _workspace = workspace;
        Show();
    }

    /// <summary>Adds and removes tiles to match the workspace and marks the selected one.</summary>
    internal void Show()
    {
        if (_workspace is not { } workspace) return;
        foreach (var (store, tile) in _tiles.Where(t => !workspace.Repos.Contains(t.Key)).ToList())
        {
            store.PropertyChanged -= OnStoreChanged;
            Tiles.Children.Remove(tile.Root);
            _tiles.Remove(store);
        }
        foreach (var store in workspace.Repos)
        {
            if (!_tiles.TryGetValue(store, out var tile))
            {
                tile = _tiles[store] = Create(workspace, store);
                Tiles.Children.Add(tile.Root);
                store.PropertyChanged += OnStoreChanged;
            }
            var selected = ReferenceEquals(store, workspace.Selected);
            tile.Marker.Visibility = selected ? Visibility.Visible : Visibility.Collapsed;
            tile.Button.CornerRadius = new CornerRadius(selected ? 14 : 18);
            ShowLook(workspace, store, tile);
            Update(store, tile);
        }
        if (workspace.Selected is null) HomeButton.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        else HomeButton.Style = (Style)Application.Current.Resources["PillButtonStyle"];
        // Dimmed until Home is the selected page.
        if (HomeButton.Content is UIElement icon) icon.Opacity = workspace.Selected is null ? 1 : 0.6;
        HomeButton.Height = 44;
        HomeButton.Padding = new Thickness(0);
        HomeButton.CornerRadius = new CornerRadius(16);
    }

    private sealed record Tile(
        Grid Root, Button Button, Border Marker, Border Badge, TextBlock Count, Border Ci,
        MenuFlyoutItem RemoveIcon)
    {
        /// <summary>The icon and colour on screen, so the button is only redrawn when they change.</summary>
        public (RepoIcon?, RepoTint?)? Look { get; set; }
    }

    private Tile Create(Workspace workspace, RepositoryStore store)
    {
        var button = new Button
        {
            Width = 46, Height = 46, Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Center,
            AllowDrop = true,
        };
        button.DragOver += (_, e) =>
        {
            if (!e.DataView.Contains(StandardDataFormats.StorageItems)
                && !e.DataView.Contains(StandardDataFormats.Bitmap)) return;
            e.AcceptedOperation = DataPackageOperation.Copy;
            e.Handled = true;
        };
        button.Drop += (_, e) =>
        {
            e.Handled = true;
            ImageDropped?.Invoke(store, e.DataView);
        };
        AutomationProperties.SetName(button, store.Name);
        button.Click += (_, _) => workspace.Select(store);

        var menu = new MenuFlyout();
        MenuFlyoutItem Add(string text, Action action)
        {
            var item = new MenuFlyoutItem { Text = text };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
            return item;
        }
        Add("Change icon…", () => IconRequested?.Invoke(store));
        var removeIcon = Add("Remove icon", () => workspace.SetIcon(store, null));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Show in File Explorer", () => Reveal(store.Id));
        Add("Copy path", () => Dialogs.Copy(store.Id));
        menu.Items.Add(new MenuFlyoutSeparator());
        Add("Close repository", () => workspace.Close(store));
        button.ContextFlyout = menu;

        var marker = new Border
        {
            Width = 4, Height = 28, CornerRadius = new CornerRadius(2), HorizontalAlignment = HorizontalAlignment.Left,
            Background = Palette.Ref(Core.RefKind.Local),
        };
        var count = new TextBlock
        {
            FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
            Foreground = new SolidColorBrush(Microsoft.UI.Colors.White), HorizontalAlignment = HorizontalAlignment.Center,
            // Tight bounds centre the digits themselves, not the font's line box.
            VerticalAlignment = VerticalAlignment.Center, TextLineBounds = TextLineBounds.Tight,
        };
        var badge = new Border
        {
            // The style adds a ring in the canvas colour that separates the badge from the tile.
            Style = (Style)Application.Current.Resources["RailBadgeStyle"],
            Background = Palette.Orange, Child = count, IsHitTestVisible = false,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 8, -5),
        };
        // The CI result of the checked-out commit, in the other corner.
        var ci = new Border
        {
            Width = 18, Height = 18, CornerRadius = new CornerRadius(9), BorderThickness = new Thickness(2),
            BorderBrush = Ui.Theme("CanvasBrush"), Visibility = Visibility.Collapsed,
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, -5, 8, 0),
        };
        var root = new Grid { Width = 75, Height = 46, Children = { button, marker, badge, ci } };
        return new Tile(root, button, marker, badge, count, ci, removeIcon);
    }

    /// <summary>Draws the tile's symbol, image or initials on its colour.</summary>
    private static void ShowLook(Workspace workspace, RepositoryStore store, Tile tile)
    {
        var icons = workspace.IconStore;
        var look = (icons.Icons.Icon(store.Id), icons.Icons.Tint(store.Id));
        if (tile.Look == look) return;
        tile.Look = look;
        var (icon, tint) = look;
        tile.RemoveIcon.Visibility = icon is null ? Visibility.Collapsed : Visibility.Visible;

        Brush background = tint is { } named ? RepoIconArt.Colour(named) : Palette.Avatar(store.Name);
        var image = icon?.Image is { } file ? RepoIconArt.Image(icons, file) : null;
        var symbol = icon?.Symbol is { } name ? RepoIconArt.Symbol(name, 20) : null;
        object? content = image is not null ? null : symbol is not null ? symbol : new TextBlock
        {
            Text = Initials(store.Name), FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.Bold,
        };
        if (image is not null) background = image;
        var white = new SolidColorBrush(Microsoft.UI.Colors.White);
        // Resources keep the look while hovered and pressed.
        var resources = tile.Button.Resources;
        resources["ButtonBackgroundPointerOver"] = resources["ButtonBackgroundPressed"] = background;
        resources["ButtonForegroundPointerOver"] = resources["ButtonForegroundPressed"] = white;
        tile.Button.Background = background;
        tile.Button.Foreground = white;
        tile.Button.Content = content;
    }

    private static string Initials(string name)
    {
        var words = name.Split(['-', '_', ' ', '.'], StringSplitOptions.RemoveEmptyEntries);
        if (words.Length > 1) return $"{words[0][0]}{words[1][0]}".ToUpperInvariant();
        return name.Length == 0 ? "?" : char.ToUpperInvariant(name[0]) + name[1..Math.Min(2, name.Length)];
    }

    /// <summary>Opens the folder itself; the path is passed as one argument, never through a shell.</summary>
    private static void Reveal(string path)
    {
        try
        {
            using var process = Process.Start(Core.OpenIn.Explorer(path));
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or IOException)
        {
            Trace.TraceWarning($"Explorer could not be started: {e.GetType().Name}");
        }
    }

    private static void Update(RepositoryStore store, Tile tile)
    {
        var changes = store.Status.ChangeCount;
        tile.Badge.Visibility = changes > 0 ? Visibility.Visible : Visibility.Collapsed;
        tile.Count.Text = changes > 99 ? "99+" : changes.ToString();
        var ci = store.HeadChecks is { } state && state != CheckState.Neutral ? state : (CheckState?)null;
        ShowCi(tile.Ci, ci);
        var result = ci switch
        {
            CheckState.Pending => "CI running",
            CheckState.Success => "CI passed",
            CheckState.Failure => "CI failed",
            _ => null,
        };
        var tip = $"{store.Name} · {store.Status.BranchDisplay}" + (result is null ? "" : $" · {result}");
        ToolTipService.SetToolTip(tile.Button, tip);
        AutomationProperties.SetName(tile.Button, result is null ? store.Name : $"{store.Name}, {result}");
    }

    private static void ShowCi(Border mark, CheckState? state)
    {
        // Rebuilt only on a change, so the spinner keeps turning smoothly.
        if (Equals(mark.Tag, state)) return;
        mark.Tag = state;
        mark.Visibility = state is null ? Visibility.Collapsed : Visibility.Visible;
        if (state is not { } shown) return;
        var running = shown == CheckState.Pending;
        mark.Background = running ? Ui.Theme("CanvasBrush") : Ui.CheckBrush(shown);
        mark.Child = running
            ? new ProgressRing
            {
                IsActive = true, Width = 12, Height = 12, MinWidth = 12, MinHeight = 12,
                Foreground = Ui.CheckBrush(shown),
            }
            : new FontIcon
            {
                Glyph = shown == CheckState.Success ? "\uE73E" : "\uE711", FontSize = 8,
                Foreground = new SolidColorBrush(Microsoft.UI.Colors.White),
            };
    }

    private void OnStoreChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName is nameof(RepositoryStore.Status) or nameof(RepositoryStore.Checks)
            && sender is RepositoryStore store
            && _tiles.TryGetValue(store, out var tile)) Update(store, tile);
    }

    private void OnHome(object sender, RoutedEventArgs e) => _workspace?.Select(null);

    private void OnSettings(object sender, RoutedEventArgs e) => SettingsRequested?.Invoke();

    private void OnAdd(object sender, RoutedEventArgs e) => AddRequested?.Invoke((FrameworkElement)sender);
}
