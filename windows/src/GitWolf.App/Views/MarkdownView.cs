using System.Text.RegularExpressions;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using Windows.UI.Text;

namespace GitWolf.App.Views;

/// <summary>Draws the safe Markdown subset with native text controls. Ported from MarkdownView.swift.</summary>
internal static class MarkdownView
{
    private static readonly FontFamily Mono = new("Consolas");

    public static UIElement Create(string source)
    {
        var panel = new StackPanel { Spacing = 8 };
        IReadOnlyList<MarkdownBlock> blocks;
        try
        {
            blocks = Markdown.Parse(source);
        }
        catch (RegexMatchTimeoutException)
        {
            // Too tangled to format: show it as it was written.
            blocks = [new MarkdownBlock(MarkdownBlockKind.Code, source[..Math.Min(source.Length, Markdown.MaxLength)])];
        }
        foreach (var block in blocks) panel.Children.Add(Block(block));
        return panel;
    }

    private static UIElement Block(MarkdownBlock block) => block.Kind switch
    {
        MarkdownBlockKind.Heading => Text(block.Text, block.Level <= 1 ? 19 : block.Level == 2 ? 16.5 : 14, bold: true),
        MarkdownBlockKind.Bullet => Item("•", block),
        MarkdownBlockKind.Numbered => Item($"{block.Marker}.", block),
        MarkdownBlockKind.Task => Item(block.Checked ? "☑" : "☐", block),
        MarkdownBlockKind.Quote => new Border
        {
            BorderThickness = new Thickness(3, 0, 0, 0), BorderBrush = Theme("PillBorderBrush"),
            Padding = new Thickness(10, 2, 0, 2), Opacity = 0.75, Child = Text(block.Text, 13),
        },
        MarkdownBlockKind.Code or MarkdownBlockKind.Table => new Border
        {
            CornerRadius = new CornerRadius(8), Background = Theme("PillFillBrush"), Padding = new Thickness(10, 8, 10, 8),
            Child = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                HorizontalScrollMode = ScrollMode.Auto,
                Content = new TextBlock
                {
                    Text = block.Text, FontFamily = Mono, FontSize = 12, IsTextSelectionEnabled = true,
                },
            },
        },
        MarkdownBlockKind.Rule => new Border { Height = 1, Background = Theme("PillBorderBrush") },
        _ => Text(block.Text, 13),
    };

    private static UIElement Item(string marker, MarkdownBlock block)
    {
        var grid = new Grid
        {
            ColumnSpacing = 8, Margin = new Thickness(block.Level * 16, 0, 0, 0),
            ColumnDefinitions = { new ColumnDefinition { Width = GridLength.Auto }, new ColumnDefinition() },
        };
        var body = Text(block.Text, 13);
        Grid.SetColumn(body, 1);
        grid.Children.Add(new TextBlock { Text = marker, FontSize = 13, MinWidth = 12 });
        grid.Children.Add(body);
        return grid;
    }

    private static TextBlock Text(string text, double size, bool bold = false)
    {
        var block = new TextBlock { FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
        if (bold) block.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        foreach (var span in Markdown.Inline(text))
        {
            var run = new Run { Text = span.Text };
            if (span.Bold) run.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            if (span.Italic) run.FontStyle = FontStyle.Italic;
            if (span.Strike) run.TextDecorations = TextDecorations.Strikethrough;
            if (span.Code) run.FontFamily = Mono;
            if (span.Link is not { } link)
            {
                block.Inlines.Add(run);
                continue;
            }
            var hyperlink = new Hyperlink { NavigateUri = link };
            hyperlink.Inlines.Add(run);
            // The real destination, since the link text can say anything.
            ToolTipService.SetToolTip(hyperlink, link.AbsoluteUri);
            block.Inlines.Add(hyperlink);
        }
        return block;
    }

    private static Brush Theme(string key) => (Brush)Application.Current.Resources[key];
}
