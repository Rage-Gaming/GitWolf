using System.Diagnostics;
using GitWolf.App.Views;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace GitWolf.App.Services;

/// <summary>Chooses a repository's tile symbol, image and colour. Ported from RepoIconPicker.</summary>
internal static class RepoIconDialog
{
    private const int Columns = 9;

    /// <param name="changed">Called after every change, so the tile updates while the dialog is open.</param>
    public static async Task ShowAsync(XamlRoot root, RepoIconStore store, string path, IntPtr window, Action changed)
    {
        var error = Ui.Error("");
        error.Visibility = Visibility.Collapsed;
        var content = new StackPanel { Spacing = 10, Width = Columns * 44 };
        var dialog = new ContentDialog
        {
            XamlRoot = root, Title = "Repository icon", CloseButtonText = "Done",
            PrimaryButtonText = "Choose image…", SecondaryButtonText = "Paste",
        };

        bool Report(bool done, string message)
        {
            error.Text = done ? "" : message;
            error.Visibility = done ? Visibility.Collapsed : Visibility.Visible;
            changed();
            return done;
        }
        bool Save(bool saved) => Report(saved, "The icon couldn’t be saved.");
        async Task UseAsync(Task<string?> import)
        {
            var done = await import is { } name
                ? Save(store.Set(path, RepoIcon.OfImage(name)))
                : Report(false, "That couldn’t be read as an image.");
            if (done) dialog.Hide();
        }

        var symbols = new StackPanel { Spacing = 8 };
        foreach (var (group, names) in RepoIcons.SymbolChoices)
        {
            symbols.Children.Add(Ui.Text(group.ToUpperInvariant(), 11, bold: true, secondary: true));
            var grid = new VariableSizedWrapGrid
            {
                Orientation = Orientation.Horizontal, MaximumRowsOrColumns = Columns, ItemWidth = 44, ItemHeight = 44,
            };
            foreach (var name in names)
            {
                if (RepoIconArt.Symbol(name, 18) is not { } icon) continue;
                var button = Ui.Button(icon, () =>
                {
                    if (Save(store.Set(path, RepoIcon.OfSymbol(name)))) dialog.Hide();
                }, name.Replace('.', ' '));
                (button.Width, button.Height, button.Padding) = (40, 40, new Thickness(0));
                grid.Children.Add(button);
            }
            symbols.Children.Add(grid);
        }
        content.Children.Add(new ScrollViewer { Content = symbols, Height = 280 });

        content.Children.Add(Ui.Text("COLOUR", 11, bold: true, secondary: true));
        var colours = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var swatches = new List<(RepoTint? Tint, Button Button)>();
        void Mark()
        {
            foreach (var (tint, button) in swatches)
                button.BorderThickness = new Thickness(tint == store.Icons.Tint(path) ? 3 : 0);
        }
        foreach (var tint in new RepoTint?[] { null }.Concat(Enum.GetValues<RepoTint>().Cast<RepoTint?>()))
        {
            var label = tint is { } named ? $"{named} colour" : "Automatic colour";
            var swatch = Ui.Button(tint is null ? "A" : "", () =>
            {
                Save(store.SetTint(path, tint));
                Mark();
            }, label);
            (swatch.Width, swatch.Height, swatch.MinWidth) = (30, 30, 30);
            (swatch.Padding, swatch.CornerRadius) = (new Thickness(0), new CornerRadius(15));
            swatch.BorderBrush = Ui.Theme("TextFillColorPrimaryBrush");
            if (tint is { } colour)
            {
                swatch.Background = RepoIconArt.Colour(colour);
                swatch.Resources["ButtonBackgroundPointerOver"] = swatch.Background;
                swatch.Resources["ButtonBackgroundPressed"] = swatch.Background;
            }
            ToolTipService.SetToolTip(swatch, label);
            swatches.Add((tint, swatch));
            colours.Children.Add(swatch);
        }
        Mark();
        content.Children.Add(colours);

        content.Children.Add(Ui.Button("Use initials", () =>
        {
            if (Save(store.Set(path, null))) dialog.Hide();
        }));
        content.Children.Add(error);
        dialog.Content = content;

        // Both image buttons keep the dialog open until the picture has been read.
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            try
            {
                var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
                foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff", ".ico" })
                    picker.FileTypeFilter.Add(type);
                WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
                if (await picker.PickSingleFileAsync() is { } file)
                    await UseAsync(RepoIconImages.ImportAsync(store, file));
            }
            catch (Exception ex)
            {
                // An event handler can't pass the failure on.
                Trace.TraceWarning($"Choosing an icon failed: {ex.GetType().Name}");
                Report(false, "The picture couldn’t be chosen.");
            }
        };
        dialog.SecondaryButtonClick += async (_, e) =>
        {
            e.Cancel = true;
            try
            {
                await UseAsync(RepoIconImages.ImportAsync(store, Clipboard.GetContent()));
            }
            catch (Exception ex)
            {
                Trace.TraceWarning($"Pasting an icon failed: {ex.GetType().Name}");
                Report(false, "The clipboard couldn’t be read.");
            }
        };
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            // Only one dialog can be open at a time.
            Trace.TraceWarning($"The icon dialog could not be shown: {e.GetType().Name}");
        }
    }
}
