using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;

namespace GitWolf.App.Views;

internal enum SidebarKind { Header, LocalBranch, RemoteBranch, Tag, Stash, RemoteGroup, Note }

internal sealed record SidebarRow(
    SidebarKind Kind, SidebarKind Section, string Title, string Trailing = "",
    string? Hash = null, Branch? Branch = null, Stash? Stash = null, bool IsOpen = false, string? Tip = null);

/// <summary>
/// A place in the list. Its row changes without the list being told, so the row stays on screen
/// instead of being removed and added again.
/// </summary>
internal sealed class SidebarItem(SidebarRow row)
{
    public SidebarRow Row { get; set; } = row;
}

public sealed partial class SidebarRowView : UserControl
{
    private static readonly Windows.UI.ViewManagement.UISettings Ui = new();
    private Storyboard? _turn;
    private Storyboard? _enter;

    public SidebarRowView() => InitializeComponent();

    /// <summary>Points the chevron right when closed and down when open.</summary>
    private void Turn(bool open, bool animate)
    {
        var from = ChevronTurn.Angle;
        var to = open ? 90 : 0;
        _turn?.Stop();
        _turn = null;
        ChevronTurn.Angle = to;
        // Follows the Windows "Animation effects" setting.
        if (!animate || from == to || !Ui.AnimationsEnabled) return;
        var animation = new DoubleAnimation
        {
            From = from, To = to, Duration = new Duration(TimeSpan.FromMilliseconds(180)),
            EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
        };
        Storyboard.SetTarget(animation, ChevronTurn);
        Storyboard.SetTargetProperty(animation, "Angle");
        _turn = new Storyboard { Children = { animation } };
        _turn.Begin();
    }

    /// <summary>A short fade and slide for a row that has just been revealed.</summary>
    internal void Enter()
    {
        if (!Ui.AnimationsEnabled) return;
        var time = new Duration(TimeSpan.FromMilliseconds(150));
        DoubleAnimation Move(DependencyObject target, string property, double from, double to)
        {
            var animation = new DoubleAnimation
            {
                From = from, To = to, Duration = time, EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut },
            };
            Storyboard.SetTarget(animation, target);
            Storyboard.SetTargetProperty(animation, property);
            return animation;
        }
        _enter = new Storyboard { Children = { Move(Root, "Opacity", 0, 1), Move(Slide, "Y", -6, 0) } };
        _enter.Begin();
    }

    /// <param name="animate">True when the same row changed; false when the view is given another row.</param>
    internal void Show(SidebarRow row, bool animate = false)
    {
        // A reused view must not carry on the previous row's entrance.
        _enter?.Stop();
        _enter = null;
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
        Chevron.Visibility = header || row.Kind == SidebarKind.RemoteGroup ? Visibility.Visible : Visibility.Collapsed;
        Turn(row.IsOpen, animate);
        Root.Padding = new Thickness(row.Kind == SidebarKind.RemoteBranch ? 20 : 0, 0, 0, 0);
        ToolTipService.SetToolTip(this, row.Branch is { } branch && !current
            ? $"{branch.Name}\nDouble-click to check out" : header || note ? null : row.Tip ?? row.Title);

        CurrentMark.Visibility = row.Kind == SidebarKind.LocalBranch && current ? Visibility.Visible : Visibility.Collapsed;
        if (row.Kind is SidebarKind.LocalBranch or SidebarKind.RemoteBranch)
        {
            // A remote branch's title already has the remote's name taken off.
            var look = FileIcons.BranchNamed(row.Title);
            DrawnIcon.Content = FileIconView.Symbol(look.Value!, FileIconView.Brush(look.Color), 14);
            return;
        }
        var (shape, brush) = row.Kind switch
        {
            SidebarKind.RemoteGroup => (Icons.Cloud, Palette.Ref(RefKind.Remote)),
            SidebarKind.Tag => (Icons.Tag, Palette.Ref(RefKind.Tag)),
            SidebarKind.Stash => (Icons.Stash, Palette.Ref(RefKind.Head)),
            _ => ((Icons.Shape?)null, Palette.Ref(RefKind.Head)),
        };
        DrawnIcon.Content = shape is null ? null : Icons.Create(shape, brush);
    }
}
