using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace GitWolf.App.Views;

/// <summary>The old and new versions of an image, side by side.</summary>
public sealed partial class ImageDiffView : Grid
{
    /// <summary>Pictures are decoded no wider than this, whatever their real size.</summary>
    private const int DecodeLimit = 1600;

    public ImageDiffView()
    {
        Padding = new Thickness(16);
        ColumnSpacing = 16;
        ColumnDefinitions.Add(new ColumnDefinition());
        ColumnDefinitions.Add(new ColumnDefinition());
    }

    public void Clear() => Children.Clear();

    public async Task ShowAsync(byte[]? old, byte[]? @new, Func<bool> stillWanted)
    {
        var left = await SideAsync("Before", old, "Did not exist");
        var right = await SideAsync("After", @new, "Deleted");
        if (!stillWanted()) return;
        Children.Clear();
        SetColumn(right, 1);
        Children.Add(left);
        Children.Add(right);
    }

    private static async Task<Grid> SideAsync(string title, byte[]? data, string absent)
    {
        var side = new Grid { RowSpacing = 8 };
        side.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        side.RowDefinitions.Add(new RowDefinition());
        side.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        side.Children.Add(new TextBlock
        {
            Text = title, FontSize = 12, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center,
        });

        FrameworkElement picture;
        var details = "";
        if (data is null) picture = Message(absent);
        else
        {
            try
            {
                var stream = new InMemoryRandomAccessStream();
                await stream.WriteAsync(data.AsBuffer());
                stream.Seek(0);
                // Reads the size from the header without decoding the pixels.
                var decoder = await BitmapDecoder.CreateAsync(stream);
                details = $"{decoder.PixelWidth} × {decoder.PixelHeight} px · {Size(data.Length)}";
                stream.Seek(0);
                var bitmap = new BitmapImage();
                // Bound the longer side, and never enlarge.
                if (Math.Max(decoder.PixelWidth, decoder.PixelHeight) > DecodeLimit)
                {
                    if (decoder.PixelWidth >= decoder.PixelHeight) bitmap.DecodePixelWidth = DecodeLimit;
                    else bitmap.DecodePixelHeight = DecodeLimit;
                }
                await bitmap.SetSourceAsync(stream);
                var image = new Image
                {
                    Source = bitmap, Stretch = Stretch.Uniform, MaxWidth = decoder.PixelWidth,
                    MaxHeight = decoder.PixelHeight,
                };
                AutomationProperties.SetName(image, $"{title} image");
                picture = image;
            }
            catch (Exception e)
            {
                // Damaged data, or a format Windows has no decoder for.
                Trace.TraceWarning($"Previewing an image failed: {e.GetType().Name}");
                picture = Message("Can’t preview this image");
                details = Size(data.Length);
            }
        }
        SetRow(picture, 1);
        side.Children.Add(picture);
        var caption = new TextBlock
        {
            Text = details, FontSize = 12, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center,
        };
        SetRow(caption, 2);
        side.Children.Add(caption);
        return side;
    }

    private static TextBlock Message(string text) => new()
    {
        Text = text, Opacity = 0.7, HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
    };

    private static string Size(long bytes) =>
        bytes < 1024 ? $"{bytes} bytes"
        : bytes < 1024 * 1024 ? $"{bytes / 1024.0:0.#} KB"
        : $"{bytes / (1024.0 * 1024):0.#} MB";
}
