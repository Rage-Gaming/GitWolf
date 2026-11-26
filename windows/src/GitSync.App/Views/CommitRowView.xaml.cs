using GitSync.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace GitSync.App.Views;

internal sealed record CommitRow(Commit Commit, GraphRow Graph, int LaneCount)
{
    public bool Equals(CommitRow? other) =>
        other is not null && LaneCount == other.LaneCount && Commit.Equals(other.Commit)
        && Graph.Lane == other.Graph.Lane && Graph.Top.SequenceEqual(other.Graph.Top)
        && Graph.Bottom.SequenceEqual(other.Graph.Bottom);

    public override int GetHashCode() => Commit.GetHashCode();
}

public sealed partial class CommitRowView : UserControl
{
    private const double LaneWidth = 14;
    private const double RowHeight = 50;
    private const int MaxRefs = 3;

    public CommitRowView() => InitializeComponent();

    internal void Show(CommitRow row)
    {
        var commit = row.Commit;
        Subject.Text = commit.Subject;
        Details.Text = $"{commit.AuthorName} · {commit.ShortHash}";
        When.Text = Relative(commit.Date);
        ToolTipService.SetToolTip(When, commit.Date.LocalDateTime.ToString("f"));

        Initials.Text = InitialsOf(commit.AuthorName);
        Avatar.Background = Palette.Avatar(commit.AuthorEmail);

        Refs.Children.Clear();
        foreach (var label in commit.Refs.Take(MaxRefs)) Refs.Children.Add(Chip(label));
        Refs.Visibility = Refs.Children.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

        Draw(row.Graph, row.LaneCount);
    }

    private static Border Chip(RefLabel label)
    {
        var brush = Palette.Ref(label.Kind);
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var icon = Icons.Create(label.Kind switch
        {
            RefKind.Tag => Icons.Tag,
            RefKind.Remote => Icons.Cloud,
            _ => Icons.Branch,
        }, brush);
        // Icons are drawn at 14px; chips use them a little smaller.
        content.Children.Add(new Viewbox { Width = 11, Height = 11, VerticalAlignment = VerticalAlignment.Center, Child = icon });
        content.Children.Add(new TextBlock
        {
            Text = label.Name, Foreground = brush, FontSize = 11, MaxWidth = 105,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        return new Border
        {
            Background = Palette.Tint(brush, label.IsCurrent ? (byte)0x38 : (byte)0x1F),
            BorderBrush = Palette.Tint(brush, label.IsCurrent ? (byte)0x59 : (byte)0x1F),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(7, 0, 7, 1),
            Child = content,
        };
    }

    internal static string InitialsOf(string name)
    {
        var initials = string.Concat(name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(2)
            .Select(w => System.Globalization.StringInfo.GetNextTextElement(w))).ToUpperInvariant();
        return initials.Length == 0 ? "?" : initials;
    }

    private static string Relative(DateTimeOffset date)
    {
        var age = DateTimeOffset.Now - date;
        return age.TotalMinutes < 1 ? "now"
            : age.TotalHours < 1 ? $"{(int)age.TotalMinutes} min ago"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours} hr ago"
            : age.TotalDays < 30 ? $"{(int)age.TotalDays} d ago"
            : age.TotalDays < 365 ? $"{(int)(age.TotalDays / 30)} mo ago"
            : $"{(int)(age.TotalDays / 365)} yr ago";
    }

    private void Draw(GraphRow row, int laneCount)
    {
        Graph.Children.Clear();
        Graph.Width = laneCount * LaneWidth;
        if (laneCount == 0) return;
        double X(int lane) => Math.Min(lane, laneCount - 1) * LaneWidth + LaneWidth / 2;
        const double middle = RowHeight / 2;

        void Edge(GraphEdge edge, double fromY, double toY, int colour)
        {
            double x1 = X(edge.From), x2 = X(edge.To), bend = (fromY + toY) / 2;
            var figure = new PathFigure { StartPoint = new Point(x1, fromY) };
            figure.Segments.Add(x1 == x2
                ? new LineSegment { Point = new Point(x2, toY) }
                : new BezierSegment { Point1 = new Point(x1, bend), Point2 = new Point(x2, bend), Point3 = new Point(x2, toY) });
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            Graph.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geometry, Stroke = Palette.Lane(colour), StrokeThickness = 2,
                StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round,
            });
        }

        foreach (var edge in row.Top) Edge(edge, 0, middle, edge.From);
        foreach (var edge in row.Bottom) Edge(edge, middle, RowHeight, edge.To);

        Graph.Children.Add(new Microsoft.UI.Xaml.Shapes.Path
        {
            Fill = Palette.Lane(row.Lane),
            Data = new EllipseGeometry { Center = new Point(X(row.Lane), middle), RadiusX = 4.5, RadiusY = 4.5 },
        });
    }
}
