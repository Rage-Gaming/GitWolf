using System.Diagnostics;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace GitWolf.App.Services;

internal static class CommitDialogs
{
    /// <summary>What a hook printed, with the choice to copy it or commit without hooks.</summary>
    public static async Task HookFailedAsync(XamlRoot root, RepositoryStore store, HookFailure failure)
    {
        var output = new TextBox
        {
            Text = failure.Output.Replace("\n", "\r"), IsReadOnly = true, AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap, FontFamily = new FontFamily("Consolas"), FontSize = 12,
            Width = 460, MaxHeight = 280,
        };
        ScrollViewer.SetVerticalScrollBarVisibility(output, ScrollBarVisibility.Auto);
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = $"The {failure.Hook} hook failed", Content = output,
            PrimaryButtonText = "Commit anyway", SecondaryButtonText = "Copy output",
            CloseButtonText = "Close", DefaultButton = ContentDialogButton.Close,
        };
        // Copying leaves the dialog open.
        dialog.SecondaryButtonClick += (_, e) =>
        {
            e.Cancel = true;
            Dialogs.Copy(failure.Output);
        };
        try
        {
            if (await dialog.ShowAsync() == ContentDialogResult.Primary)
                await store.CommitAsync(failure.Sign, skipHooks: true);
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Showing hook output failed: {e.GetType().Name}");
        }
    }
}
