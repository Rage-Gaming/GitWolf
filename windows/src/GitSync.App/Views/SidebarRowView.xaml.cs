using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitSync.App.Views;

internal enum SidebarKind { Header, LocalBranch, RemoteBranch, Tag, Stash, RemoteGroup, Note }

internal sealed record SidebarRow(
    SidebarKind Kind, SidebarKind Section, string Title, string Trailing = "",
    string? Hash = null, Branch? Branch = null, Stash? Stash = null, bool IsOpen = false);

public sealed partial class SidebarRowView : UserControl
{
    public SidebarRowView() => InitializeComponent();

    internal void Show(SidebarRow row)
    {
        var header = row.Kind == SidebarKind.Header;
        var note = row.Kind == SidebarKind.Note;
        var current = row.Branch is { IsCurrent: true };
        HeaderPanel.Visibility = header ? Visibility.Visible : Visibility.Collapsed;
        DrawnIcon.Visibility = header || note ? Visibility.Collapsed : Visibility.Visible;
        Header.Text = header ? row.Title : "";
        Count.Text = header ? row.Trailing : "";
        Label.Text = header ? "" : row.Title;
        Label.FontWeight = current ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal;
        Label.Opacity = note ? 0.5 : 1;
        Trailing.Text = header ? "" : row.Trailing;
        // Remote groups and their branches: chevron before the group, indent under it.
        Chevron.Glyph = header || row.Kind == SidebarKind.RemoteGroup ? row.IsOpen ? "\uE70D" : "\uE76C" : "";
        Root.Padding = new Thickness(row.Kind == SidebarKind.RemoteBranch ? 20 : 0, 0, 0, 0);
        ToolTipService.SetToolTip(this, row.Branch is { } branch && !current
            ? $"{branch.Name}\nDouble-click to check out" : header || note ? null : row.Title);

        var (shape, brush) = row.Kind switch
        {
            SidebarKind.LocalBranch when current => (Icons.Check, Palette.Green),
            SidebarKind.LocalBranch => (Icons.Branch, Palette.Ref(RefKind.Head)),
            SidebarKind.RemoteBranch => (Icons.Branch, Palette.Ref(RefKind.Remote)),
            SidebarKind.RemoteGroup => (Icons.Cloud, Palette.Ref(RefKind.Remote)),
            SidebarKind.Tag => (Icons.Tag, Palette.Ref(RefKind.Tag)),
            SidebarKind.Stash => (Icons.Stash, Palette.Ref(RefKind.Head)),
            _ => ((Icons.Shape?)null, Palette.Ref(RefKind.Head)),
        };
        DrawnIcon.Content = shape is null ? null : Icons.Create(shape, brush);
    }
}
