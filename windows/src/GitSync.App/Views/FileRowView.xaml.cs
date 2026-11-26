using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

/// <summary>A file, or (when <see cref="File"/> is null) a section header.</summary>
internal sealed record FileRow(FileChange? File, DiffSource Source, string? Header = null);

public sealed partial class FileRowView : UserControl
{
    private Action? _action;

    public FileRowView() => InitializeComponent();

    internal void Show(FileRow row, string? actionLabel, Action? action)
    {
        _action = action;
        Action.Content = actionLabel;
        Action.Visibility = actionLabel is null ? Visibility.Collapsed : Visibility.Visible;
        Header.Text = row.Header ?? "";

        if (row.File is not { } file)
        {
            Badge.Background = Palette.Clear;
            Kind.Text = NameText.Text = PathText.Text = "";
            TypeIcon.Show(null);
            FolderIcon.Show(null);
            ToolTipService.SetToolTip(this, null);
            return;
        }
        var (letter, brush, fill) = Palette.Status(file.Kind);
        Badge.Background = fill;
        Kind.Text = letter;
        Kind.Foreground = brush;
        NameText.Text = file.FileName;
        PathText.Text = file.Directory;
        TypeIcon.Show(FileIcons.ForPath(file.Path));
        FolderIcon.Show(FileIcons.FolderContaining(file.Path));
        ToolTipService.SetToolTip(this, file.OriginalPath is { } from ? $"{from} → {file.Path}" : file.Path);
    }

    private void OnAction(object sender, RoutedEventArgs e) => _action?.Invoke();
}
