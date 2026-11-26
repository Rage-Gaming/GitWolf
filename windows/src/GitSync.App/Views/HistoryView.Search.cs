using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

// Search options. The plain search filters what is loaded; anything narrower is asked of git.
public sealed partial class HistoryView
{
    private static readonly GraphRow NoGraph = new(0, [], [], 0);

    private readonly ComboBox _kind = new()
    {
        Header = "Search in", HorizontalAlignment = HorizontalAlignment.Stretch,
        ItemsSource = new[]
        {
            "Loaded commits", "Commit messages", "Authors", "Text added or removed", "Changed lines (regex)",
        },
    };
    private readonly TextBox _path = new() { Header = "Only this file or folder", PlaceholderText = "src/app" };
    private readonly CalendarDatePicker _since = new() { Header = "From", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly CalendarDatePicker _until = new() { Header = "To", HorizontalAlignment = HorizontalAlignment.Stretch };
    /// <summary>Waits for typing to pause before asking git.</summary>
    private DispatcherTimer? _delay;
    private bool _resetting;

    private bool GitSearch => Query() is { IsEmpty: false };

    private HistoryQuery? Query()
    {
        var path = _path.Text.Trim();
        var narrowed = path.Length > 0 || _since.Date is not null || _until.Date is not null;
        if (_kind.SelectedIndex <= 0 && !narrowed) return null;
        static DateOnly? Day(DateTimeOffset? date) =>
            date is { } d ? DateOnly.FromDateTime(d.LocalDateTime) : null;
        // With only a file or dates chosen, typed text still means the message.
        var kind = (HistorySearchKind)Math.Max(0, _kind.SelectedIndex - 1);
        return new HistoryQuery(kind, Search.Text, path, Day(_since.Date), Day(_until.Date));
    }

    private void BuildSearchOptions()
    {
        _kind.SelectedIndex = 0;
        var clear = new Button { Content = "Clear" };
        clear.Click += (_, _) =>
        {
            ResetSearch();
            QueueSearch();
        };
        Options.Flyout = new Flyout
        {
            Content = new StackPanel { Spacing = 10, Width = 260, Children = { _kind, _path, _since, _until, clear } },
        };
        _kind.SelectionChanged += (_, _) => QueueSearch();
        _path.TextChanged += (_, _) => QueueSearch();
        _since.DateChanged += (_, _) => QueueSearch();
        _until.DateChanged += (_, _) => QueueSearch();
    }

    private void ResetSearch()
    {
        _resetting = true;
        Search.Text = "";
        _kind.SelectedIndex = 0;
        _path.Text = "";
        _since.Date = _until.Date = null;
        _resetting = false;
        _delay?.Stop();
        _ = _store?.SearchAsync(null);
    }

    private void OnSearch(object sender, TextChangedEventArgs e) => QueueSearch();

    private void QueueSearch()
    {
        if (_resetting) return;
        Options.Content = GitSearch || _kind.SelectedIndex > 0 ? "Options •" : "Options";
        if (_delay is null)
        {
            _delay = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(300) };
            _delay.Tick += (_, _) =>
            {
                _delay.Stop();
                _ = _store?.SearchAsync(Query());
                ShowCommits();
            };
        }
        _delay.Stop();
        if (GitSearch) _delay.Start();
        else
        {
            _ = _store?.SearchAsync(null);
            ShowCommits();
        }
    }
}
