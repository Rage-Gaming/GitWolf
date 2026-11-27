using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace GitWolf.App.Views;

/// <summary>The row that stands for folded unchanged lines; clicking it shows them.</summary>
internal static class FoldButton
{
    /// <summary>Adds the button on first use, then shows it for a fold and hides it otherwise.</summary>
    public static void Place(Grid row, ref Button? button, DiffLine? fold, int columns, Action<DiffLine> open)
    {
        if (fold is null)
        {
            if (button is not null) button.Visibility = Visibility.Collapsed;
            return;
        }
        if (button is null)
        {
            var created = new Button
            {
                Style = (Style)Application.Current.Resources["PlainButtonStyle"],
                HorizontalAlignment = HorizontalAlignment.Left, Height = 20, MinHeight = 0,
                Padding = new Thickness(48, 0, 12, 0), FontSize = 12,
            };
            // Rows are reused, so the handler reads what the button stands for when clicked.
            created.Click += (_, _) =>
            {
                if (created.Tag is (DiffLine line, Action<DiffLine> unfold)) unfold(line);
            };
            Grid.SetColumnSpan(created, columns);
            row.Children.Add(created);
            button = created;
        }
        button.Tag = (fold, open);
        button.Content = fold.Text;
        button.Visibility = Visibility.Visible;
    }
}
