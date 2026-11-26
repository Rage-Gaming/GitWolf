using System.Collections.ObjectModel;
using System.Globalization;
using GitSync.App.Services;
using GitSync.Core;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitSync.App.Views;

/// <summary>Header and file list of the selected commit. Ported from CommitDetailView.swift.</summary>
public sealed partial class CommitDetailView : UserControl
{
    private readonly ObservableCollection<FileRow> _files = [];
    private RepositoryStore? _store;
    private string? _shownHash;
    private bool _syncing;

    public CommitDetailView()
    {
        InitializeComponent();
        Files.ItemsSource = _files;
    }

    internal void Show(RepositoryStore store)
    {
        if (!ReferenceEquals(_store, store))
        {
            _store = store;
            _shownHash = null;
        }
        if (store.SelectedCommit is not { } commit) return;

        var parts = store.CommitMessage.Split('\n', 2);
        Subject.Text = parts[0].Trim().Length > 0 ? parts[0].Trim() : commit.Subject;
        Body.Text = parts.Length > 1 ? parts[1].Trim() : "";
        BodyScroll.Visibility = Body.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;

        if (_shownHash != commit.Hash)
        {
            _shownHash = commit.Hash;
            Author.Text = commit.AuthorName;
            var date = commit.Date.LocalDateTime;
            Date.Text = string.Create(CultureInfo.CurrentCulture, $"{date:d MMM yyyy} at {date:t}");
            Initials.Text = CommitRowView.InitialsOf(commit.AuthorName);
            Avatar.Background = Palette.Avatar(commit.AuthorEmail);
            Hash.Text = commit.ShortHash;
            ShowParents(commit);
        }

        var source = DiffSource.ForCommit(commit.Hash);
        _syncing = true;
        ListSync.Apply(_files, store.CommitFiles.Select(f => new FileRow(f, source)).ToList(), r => r.File!.Path);
        Files.SelectedItem = _files.FirstOrDefault(r => r.File?.Path == store.SelectedTarget?.Path);
        _syncing = false;
    }

    private void ShowParents(Commit commit)
    {
        Parents.Children.Clear();
        Parents.Visibility = commit.Parents.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (commit.Parents.Count == 0) return;
        Parents.Children.Add(new TextBlock
        {
            Text = commit.Parents.Count > 1 ? "Parents" : "Parent", FontSize = 11.5, Opacity = 0.6,
            VerticalAlignment = VerticalAlignment.Center,
        });
        foreach (var parent in commit.Parents)
        {
            var link = new HyperlinkButton
            {
                Content = parent[..Math.Min(7, parent.Length)], FontSize = 11.5, Padding = new Thickness(0),
                FontFamily = new FontFamily("Consolas"),
            };
            link.Click += (_, _) => _store?.Reveal(parent);
            Parents.Children.Add(link);
        }
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        if (_store?.SelectedCommit is { } commit) Dialogs.Copy(commit.Hash);
    }

    private void OnFileSelected(object sender, SelectionChangedEventArgs e)
    {
        if (!_syncing && Files.SelectedItem is FileRow { File: { } file } row) _store?.SelectChange(file, row.Source);
    }

    private void OnFileRow(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (!args.InRecycleQueue && args.ItemContainer.ContentTemplateRoot is FileRowView view && args.Item is FileRow row)
            view.Show(row, null, null);
    }
}
