using System.Diagnostics;
using System.Runtime.InteropServices.WindowsRuntime;
using GitWolf.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace GitWolf.App.Services;

/// <summary>Turns any picture into the small square image a repository tile shows.</summary>
internal static class RepoIconImages
{
    private const uint Side = 128;
    private const ulong MaxBytes = 50 * 1024 * 1024;

    /// <summary>Crops to a centred square and saves a 128 px PNG. Returns the stored name, or null.</summary>
    public static async Task<string?> ImportAsync(RepoIconStore store, IRandomAccessStream source)
    {
        try
        {
            if (source.Size > MaxBytes) return null;
            var decoder = await BitmapDecoder.CreateAsync(source);
            var (width, height) = (decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
            if (width == 0 || height == 0) return null;
            // Scaled so the shorter side fits, then cropped; the decoder only produces the small image.
            var scale = (double)Side / Math.Min(width, height);
            var scaledWidth = Math.Max(Side, (uint)Math.Round(width * scale));
            var scaledHeight = Math.Max(Side, (uint)Math.Round(height * scale));
            // The crop applies after rotation, the scale before it.
            var turned = decoder.PixelWidth != decoder.OrientedPixelWidth;
            var transform = new BitmapTransform
            {
                ScaledWidth = turned ? scaledHeight : scaledWidth,
                ScaledHeight = turned ? scaledWidth : scaledHeight,
                InterpolationMode = BitmapInterpolationMode.Fant,
                Bounds = new BitmapBounds
                {
                    X = (scaledWidth - Side) / 2, Y = (scaledHeight - Side) / 2, Width = Side, Height = Side,
                },
            };
            var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
                transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);

            using var encoded = new InMemoryRandomAccessStream();
            var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, encoded);
            encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, Side, Side, 96, 96,
                pixels.DetachPixelData());
            await encoder.FlushAsync();
            var bytes = new byte[encoded.Size];
            await encoded.GetInputStreamAt(0).ReadAsync(bytes.AsBuffer(), (uint)bytes.Length, InputStreamOptions.None);
            var name = RepoIconStore.NewImageName();
            await File.WriteAllBytesAsync(store.ImagePath(name), bytes);
            return name;
        }
        catch (Exception e)
        {
            // The codecs report an unreadable picture with many different COM errors.
            Trace.TraceWarning($"Importing an icon failed: {e.GetType().Name}");
            return null;
        }
    }

    public static async Task<string?> ImportAsync(RepoIconStore store, StorageFile file)
    {
        try
        {
            using var stream = await file.OpenReadAsync();
            return await ImportAsync(store, stream);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Opening a picture failed: {e.GetType().Name}");
            return null;
        }
    }

    /// <summary>The first file or picture in a drop or on the clipboard; null when it can't be used.</summary>
    public static async Task<string?> ImportAsync(RepoIconStore store, DataPackageView data)
    {
        try
        {
            if (data.Contains(StandardDataFormats.StorageItems))
                return (await data.GetStorageItemsAsync()).OfType<StorageFile>().FirstOrDefault() is { } file
                    ? await ImportAsync(store, file)
                    : null;
            if (!data.Contains(StandardDataFormats.Bitmap)) return null;
            using var stream = await (await data.GetBitmapAsync()).OpenReadAsync();
            return await ImportAsync(store, stream);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Reading a picture failed: {e.GetType().Name}");
            return null;
        }
    }
}
