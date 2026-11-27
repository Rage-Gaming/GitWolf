using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Views;

/// <summary>Small building blocks shared by the views that are built in code for provider features.</summary>
internal static class Ui
{
    public static TextBlock Text(string text, double size = 13, bool bold = false, bool secondary = false, bool wrap = true)
    {
        var block = new TextBlock
        {
            Text = text, FontSize = size,
            TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
            TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        };
        if (bold) block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        if (secondary) block.Opacity = 0.65;
        return block;
    }

    public static TextBlock Error(string text) => new()
    {
        Text = text, FontSize = 12.5, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        Foreground = Palette.Orange,
    };

    public static StackPanel Row(double spacing, params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }

    public static Button Button(object content, Action click, string? name = null)
    {
        var button = new Button { Content = content };
        if (name is not null) AutomationProperties.SetName(button, name);
        button.Click += (_, _) => click();
        return button;
    }

    /// <summary>A flat, rounded label such as a state or a repository label.</summary>
    public static Border Chip(string text, Brush? colour = null) => new()
    {
        CornerRadius = new CornerRadius(8), Padding = new Thickness(8, 1, 8, 2), VerticalAlignment = VerticalAlignment.Center,
        BorderThickness = new Thickness(1), BorderBrush = colour ?? Theme("PillBorderBrush"),
        Background = Theme("PillFillBrush"),
        Child = new TextBlock { Text = text, FontSize = 11, Foreground = colour ?? Theme("TextFillColorPrimaryBrush") },
    };

    public static Brush Theme(string key) => (Brush)Application.Current.Resources[key];

    public static Brush CheckBrush(CheckState state) => state switch
    {
        CheckState.Success => Palette.Green,
        CheckState.Failure => Palette.Red,
        CheckState.Pending => Palette.Orange,
        _ => Theme("TextFillColorSecondaryBrush"),
    };

    public static string CheckGlyph(CheckState state) => state switch
    {
        CheckState.Success => "",
        CheckState.Failure => "",
        CheckState.Pending => "",
        _ => "",
    };

    /// <summary>"3h ago" style, for lists.</summary>
    public static string Ago(DateTimeOffset? time)
    {
        if (time is not { } t) return "";
        var age = DateTimeOffset.UtcNow - t;
        return age.TotalMinutes < 1 ? "now"
            : age.TotalHours < 1 ? $"{(int)age.TotalMinutes}m ago"
            : age.TotalDays < 1 ? $"{(int)age.TotalHours}h ago"
            : age.TotalDays < 30 ? $"{(int)age.TotalDays}d ago"
            : t.LocalDateTime.ToString("d MMM yyyy");
    }
}
