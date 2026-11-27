using System.Diagnostics;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;

namespace GitSync.App.Views;

/// <summary>
/// Resolves one conflicted file: pick ours, theirs or both for each block, then save and stage it.
/// Files without markers (deleted on one side, binary) get whole-file choices. Ported from
/// ConflictResolverView.swift.
/// </summary>
public sealed partial class ConflictView : UserControl
{
    /// <summary>Longer sides are cut for display; saving always uses the whole text.</summary>
    private const int MaxShownLines = 200;
    private const int MaxShownBlocks = 100;

    private readonly Grid _root = new()
    {
        RowDefinitions =
        {
            new RowDefinition { Height = GridLength.Auto },
            new RowDefinition { Height = new GridLength(1, GridUnitType.Star) },
            new RowDefinition { Height = GridLength.Auto },
        },
    };
    private readonly Dictionary<int, ConflictChoice> _choices = [];
    private readonly List<Action> _refresh = [];
    private readonly List<Control> _actions = [];
    private RepositoryStore? _store;
    private string? _path;
    private ConflictDocument? _document;
    private Button? _resolve;
    private TextBlock? _progress;
    private int _token;

    public ConflictView() => Content = _root;

    /// <summary>Reloads when the file shown, or its content, changed.</summary>
    internal void Show(RepositoryStore store, string? path)
    {
        var same = ReferenceEquals(store, _store) && path == _path;
        _store = store;
        _path = path;
        if (path is null)
        {
            _token++;
            _document = null;
            _root.Children.Clear();
            return;
        }
        _ = LoadAsync(store, path, same);
    }

    private async Task LoadAsync(RepositoryStore store, string path, bool same)
    {
        var token = ++_token;
        var repo = store.Repo;
        ConflictStages? stages = null;
        ConflictDocument? document = null;
        try
        {
            (stages, document) = await Task.Run(async () =>
                (await repo.ConflictStagesAsync(path), await repo.ConflictDocumentAsync(path)));
        }
        catch (Exception e) when (e is GitException or IOException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Loading a conflict failed: {e.GetType().Name}");
        }
        if (token != _token) return;
        // Unchanged content keeps the choices made so far.
        if (same && _root.Children.Count > 0 && document?.Source == _document?.Source) return;

        _document = document;
        _choices.Clear();
        _refresh.Clear();
        _actions.Clear();
        _resolve = null;
        _progress = null;
        _root.Children.Clear();
        Put(Header(path, stages), 0);
        if (document is null) Put(WholeFile(stages), 1);
        else ShowBlocks(document);
        ShowState();
    }

    private void Put(FrameworkElement element, int row)
    {
        Grid.SetRow(element, row);
        _root.Children.Add(element);
    }

    private static TextBlock Text(string text, double size = 13, bool bold = false) => new()
    {
        Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center,
        FontWeight = bold ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
    };

    private static FrameworkElement Header(string path, ConflictStages? stages)
    {
        var name = Text(path, bold: true);
        name.TextWrapping = TextWrapping.NoWrap;
        name.TextTrimming = TextTrimming.CharacterEllipsis;
        var kind = Text(stages?.Title ?? "Conflict", 12, true);
        kind.Foreground = new SolidColorBrush(Colors.IndianRed);
        Grid.SetColumn(kind, 1);
        return new Grid
        {
            Padding = new Thickness(14, 12, 14, 12), ColumnSpacing = 10,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children = { name, kind },
        };
    }

    private Button Action(string text, Action run)
    {
        var button = new Button { Content = text, FontSize = 12 };
        button.Click += (_, _) => run();
        _actions.Add(button);
        return button;
    }

    private void ShowBlocks(ConflictDocument document)
    {
        var list = new StackPanel { Spacing = 12, Padding = new Thickness(14, 0, 14, 14) };
        foreach (var block in document.Blocks.Take(MaxShownBlocks)) list.Children.Add(Card(block, document.Blocks.Count));
        if (document.Blocks.Count > MaxShownBlocks)
            list.Children.Add(Text($"Only the first {MaxShownBlocks} conflicts are shown. Use All ours, All theirs "
                + "or your editor.", 12));
        Put(new ScrollViewer { Content = list }, 1);

        _progress = Text("", 12);
        void All(ConflictChoice choice)
        {
            foreach (var block in document.Blocks) _choices[block.Id] = choice;
            ShowState();
        }
        _resolve = new Button { Content = "Mark as resolved", FontSize = 12 };
        _resolve.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _resolve.Click += (_, _) =>
        {
            if (_path is { } path)
                _ = _store?.ResolveConflictAsync(path, document.Render(_choices), document.Source);
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8,
            Children =
            {
                Action("All ours", () => All(ConflictChoice.Ours)),
                Action("All theirs", () => All(ConflictChoice.Theirs)),
                _resolve,
            },
        };
        Grid.SetColumn(buttons, 1);
        Put(new Grid
        {
            Padding = new Thickness(14, 10, 14, 10), ColumnSpacing = 10,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = GridLength.Auto },
            },
            Children = { _progress, buttons },
        }, 2);
    }

    private FrameworkElement Card(ConflictBlock block, int total)
    {
        var ours = Side("Ours", block.OursLabel, block.Ours);
        var theirs = Side("Theirs", block.TheirsLabel, block.Theirs);
        Grid.SetColumn(theirs, 1);

        var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        foreach (var (choice, title) in new[]
                 {
                     (ConflictChoice.Ours, "Ours"), (ConflictChoice.Theirs, "Theirs"),
                     (ConflictChoice.Both, "Both"), (ConflictChoice.BothReversed, "Both, theirs first"),
                 })
        {
            var toggle = new ToggleButton { Content = title, FontSize = 11 };
            toggle.Click += (_, _) =>
            {
                _choices[block.Id] = choice;
                ShowState();
            };
            _actions.Add(toggle);
            _refresh.Add(() => toggle.IsChecked = _choices.TryGetValue(block.Id, out var c) && c == choice);
            choices.Children.Add(toggle);
        }
        _refresh.Add(() =>
        {
            var chosen = _choices.TryGetValue(block.Id, out var c) ? c : (ConflictChoice?)null;
            ours.Opacity = chosen == ConflictChoice.Theirs ? 0.4 : 1;
            theirs.Opacity = chosen == ConflictChoice.Ours ? 0.4 : 1;
        });

        var sides = new Grid
        {
            ColumnSpacing = 1,
            ColumnDefinitions =
            {
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
                new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) },
            },
            Children = { ours, theirs },
        };
        return new Border
        {
            CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
            BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(80, 128, 128, 128)),
            Child = new StackPanel
            {
                Children =
                {
                    new StackPanel
                    {
                        Padding = new Thickness(10, 8, 10, 8), Spacing = 6,
                        Children = { Text($"Conflict {block.Id + 1} of {total}", 12, true), choices },
                    },
                    sides,
                },
            },
        };
    }

    private static Grid Side(string role, string label, IReadOnlyList<string> lines)
    {
        var shown = string.Join('\n', lines.Take(MaxShownLines).Select(l =>
            l.TrimEnd('\r') is { Length: > DiffRowView.MaxColumns } longLine ? longLine[..DiffRowView.MaxColumns] : l.TrimEnd('\r')));
        if (lines.Count > MaxShownLines) shown += $"\n… {lines.Count - MaxShownLines} more lines";
        var code = new TextBlock
        {
            Text = lines.Count == 0 ? "(empty)" : shown, FontFamily = new FontFamily("Consolas"), FontSize = 12,
            TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        };
        var title = Text($"{role}  {label}", 11, true);
        title.TextWrapping = TextWrapping.NoWrap;
        title.TextTrimming = TextTrimming.CharacterEllipsis;
        return new Grid
        {
            Background = role == "Ours"
                ? new SolidColorBrush(Windows.UI.Color.FromArgb(24, 64, 128, 255))
                : new SolidColorBrush(Windows.UI.Color.FromArgb(24, 64, 192, 96)),
            Children =
            {
                new StackPanel { Padding = new Thickness(10, 6, 10, 10), Spacing = 6, Children = { title, code } },
            },
        };
    }

    /// <summary>For files without markers to edit.</summary>
    private FrameworkElement WholeFile(ConflictStages? stages)
    {
        var explanation = stages switch
        {
            { Ours: true, Theirs: false } => "Your side changed this file, but the other side deleted it. "
                + "Keep your version or delete the file.",
            { Ours: false, Theirs: true } => "Your side deleted this file, but the other side changed it. "
                + "Keep their version or delete the file.",
            { HasContentConflict: true } => "This file has no conflict markers that can be edited here (it may be "
                + "binary, large or already edited). Pick a side or mark it resolved.",
            _ => "Choose how to resolve this file.",
        };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center,
        };
        void Offer(string title, Func<RepositoryStore, string, Task> run) => buttons.Children.Add(Action(title, () =>
        {
            if (_store is { } store && _path is { } path) _ = run(store, path);
        }));
        if (stages?.Ours != false) Offer("Keep ours", (s, p) => s.ResolveConflictAsync(p, ConflictSide.Ours));
        if (stages?.Theirs != false) Offer("Keep theirs", (s, p) => s.ResolveConflictAsync(p, ConflictSide.Theirs));
        if (stages is { HasContentConflict: false })
            Offer("Delete file", (s, p) => s.ResolveConflictAsync(p, ConflictSide.Delete));
        if (stages?.HasContentConflict == true) Offer("Mark as resolved", (s, p) => s.StageAsync([p]));

        var message = Text(explanation);
        message.HorizontalTextAlignment = TextAlignment.Center;
        message.MaxWidth = 360;
        return new StackPanel
        {
            Spacing = 14, Padding = new Thickness(20), VerticalAlignment = VerticalAlignment.Center,
            Children = { message, buttons },
        };
    }

    /// <summary>Updates choices, progress and whether buttons can be used.</summary>
    internal void ShowState()
    {
        var idle = _store?.IsBusy != true;
        foreach (var action in _actions) action.IsEnabled = idle;
        foreach (var refresh in _refresh) refresh();
        if (_document is not { } document || _resolve is null || _progress is null) return;
        _progress.Text = $"{_choices.Count} of {document.Blocks.Count} resolved";
        _resolve.IsEnabled = idle && _choices.Count == document.Blocks.Count;
    }
}
