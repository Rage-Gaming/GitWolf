using System.Diagnostics;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.System;

namespace GitWolf.App.Services;

internal enum UpdateChoice { Install, Skip, Later }

/// <summary>The updater's prompts.</summary>
internal static class UpdateDialogs
{
    private static ContentDialog Dialog(XamlRoot root, string title, object content) => new()
    {
        RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
        XamlRoot = root, Title = title, Content = content,
    };

    private static TextBlock Text(string text) => new() { Text = text, TextWrapping = TextWrapping.Wrap };

    /// <summary>Null when no dialog could be shown, because WinUI allows one at a time.</summary>
    private static async Task<ContentDialogResult?> ShowAsync(ContentDialog dialog)
    {
        try
        {
            return await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Update dialog could not be shown: {e.GetType().Name}");
            return null;
        }
    }

    public static async Task InformAsync(XamlRoot root, string title, string message)
    {
        var dialog = Dialog(root, title, Text(message));
        dialog.CloseButtonText = "OK";
        await ShowAsync(dialog);
    }

    /// <summary>Explains a failed installation and offers the download page.</summary>
    public static async Task FailedAsync(XamlRoot root, string message)
    {
        var dialog = Dialog(root, "Couldn’t update", Text(message));
        dialog.PrimaryButtonText = "Open releases page";
        dialog.CloseButtonText = "Close";
        if (await ShowAsync(dialog) == ContentDialogResult.Primary)
            await Launcher.LaunchUriAsync(new Uri(Updater.ReleasesPage));
    }

    public static async Task<UpdateChoice?> OfferAsync(XamlRoot root, AppVersion current, AppcastItem release)
    {
        var content = new StackPanel { Spacing = 12, MinWidth = 400 };
        content.Children.Add(Text($"You have {current}. GitWolf restarts to finish installing."));
        if (release.Notes.Length > 0)
            // Plain text: nothing from the feed is rendered or made clickable.
            content.Children.Add(new ScrollViewer
            {
                MaxHeight = 260,
                Content = new TextBlock { Text = release.Notes, TextWrapping = TextWrapping.Wrap, FontSize = 12.5 },
            });
        var dialog = Dialog(root, $"GitWolf {release.Version} is available", content);
        dialog.PrimaryButtonText = "Install and Relaunch";
        dialog.SecondaryButtonText = "Skip This Version";
        dialog.CloseButtonText = "Remind Me Later";
        dialog.DefaultButton = ContentDialogButton.Primary;
        return await ShowAsync(dialog) switch
        {
            null => null,
            ContentDialogResult.Primary => UpdateChoice.Install,
            ContentDialogResult.Secondary => UpdateChoice.Skip,
            _ => UpdateChoice.Later,
        };
    }

    /// <summary>
    /// Runs <paramref name="work"/> behind a progress dialog. It can be cancelled until the work calls
    /// the action saying that files are being replaced. False when cancelled or not done.
    /// </summary>
    public static async Task<bool> ProgressAsync(XamlRoot root, string version,
        Func<IProgress<double>, Action, CancellationToken, Task<bool>> work)
    {
        var bar = new ProgressBar { Maximum = 1 };
        var status = Text("Downloading…");
        var dialog = Dialog(root, $"Updating to GitWolf {version}",
            new StackPanel { Spacing = 12, MinWidth = 400, Children = { status, bar } });
        dialog.CloseButtonText = "Cancel";

        using var cancel = new CancellationTokenSource();
        var installing = false;
        var finished = false;
        // Escape and Cancel both close the dialog; neither may interrupt replacing files.
        dialog.Closing += (_, e) =>
        {
            if (finished) return;
            if (installing) e.Cancel = true;
            else cancel.Cancel();
        };
        var shown = ShowAsync(dialog);
        // Not shown: another dialog is open, and the user couldn't see or cancel the download.
        if (shown.IsCompleted && await shown is null) return false;
        try
        {
            return await work(new Progress<double>(value => bar.Value = value), () =>
            {
                installing = true;
                status.Text = "Installing…";
                bar.IsIndeterminate = true;
                dialog.CloseButtonText = "";
            }, cancel.Token);
        }
        catch (OperationCanceledException) when (cancel.IsCancellationRequested)
        {
            return false;
        }
        finally
        {
            finished = true;
            dialog.Hide();
            await shown;
        }
    }
}
