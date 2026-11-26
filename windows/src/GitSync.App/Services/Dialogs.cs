using System.Diagnostics;
using GitSync.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace GitSync.App.Services;

/// <summary>Small prompts shared by the views.</summary>
internal static class Dialogs
{
    public static async Task NewBranchAsync(XamlRoot root, RepositoryStore store, string? from)
    {
        var toggle = new CheckBox { Content = "Switch to the new branch", IsChecked = true };
        if (await PromptAsync(root, "New branch", "branch-name", "Create", toggle) is { } name)
            await store.CreateBranchAsync(name, from, toggle.IsChecked == true);
    }

    public static async Task NewTagAsync(XamlRoot root, RepositoryStore store, string hash)
    {
        if (await PromptAsync(root, "New tag", "v1.0.0", "Create") is { } name)
            await store.CreateTagAsync(name, hash);
    }

    public static async Task StashAsync(XamlRoot root, RepositoryStore store)
    {
        if (await PromptAsync(root, "Stash changes", "Message (optional)", "Stash", allowEmpty: true) is { } message)
            await store.StashPushAsync(message);
    }

    public static void Copy(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
    }

    /// <summary>Returns the trimmed text, or null when cancelled.</summary>
    private static async Task<string?> PromptAsync(
        XamlRoot root, string title, string placeholder, string confirm, UIElement? extra = null, bool allowEmpty = false)
    {
        var input = new TextBox { PlaceholderText = placeholder };
        var content = new StackPanel { Spacing = 12, Children = { input } };
        if (extra is not null) content.Children.Add(extra);
        var dialog = new ContentDialog
        {
            // Dialogs don't inherit a theme forced on the window content.
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = title, Content = content, PrimaryButtonText = confirm, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = allowEmpty,
        };
        input.TextChanged += (_, _) => dialog.IsPrimaryButtonEnabled = allowEmpty || input.Text.Trim().Length > 0;
        try
        {
            return await dialog.ShowAsync() == ContentDialogResult.Primary ? input.Text.Trim() : null;
        }
        catch (Exception e)
        {
            // WinUI allows one dialog at a time.
            Trace.TraceWarning($"Dialog could not be shown: {e.GetType().Name}");
            return null;
        }
    }
}
