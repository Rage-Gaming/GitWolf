using System.Diagnostics;
using GitWolf.Core;
using GitWolf.Store;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;

namespace GitWolf.App.Services;

/// <summary>Small prompts shared by the views.</summary>
internal static class Dialogs
{
    public static async Task NewBranchAsync(XamlRoot root, RepositoryStore store, string? from)
    {
        var toggle = new CheckBox { Content = "Switch to the new branch", IsChecked = true };
        if (await PromptAsync(root, "New branch", "branch-name", "Create", toggle) is { } name)
            await store.CreateBranchAsync(name, from, toggle.IsChecked == true);
    }

    /// <summary>A lightweight tag, or an annotated one when a message is given, optionally pushed.</summary>
    public static async Task NewTagAsync(XamlRoot root, RepositoryStore store, string hash)
    {
        var message = new TextBox
        {
            PlaceholderText = "Message (optional)", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap,
            MinHeight = 76, MaxHeight = 140,
        };
        var remote = store.Remotes.Contains("origin") ? "origin" : store.Remotes.FirstOrDefault();
        var push = new CheckBox { Content = $"Push to {remote}" };
        var extra = new StackPanel
        {
            Spacing = 8, MinWidth = 380,
            Children =
            {
                message,
                new TextBlock
                {
                    Text = "With a message the tag is annotated: it records who tagged and when.",
                    TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.7,
                },
            },
        };
        if (remote is not null) extra.Children.Add(push);
        var title = $"New tag at {hash[..Math.Min(7, hash.Length)]}";
        if (await PromptAsync(root, title, "v1.0.0", "Create", extra) is { } name)
            await store.CreateTagAsync(name, hash, message.Text.ReplaceLineEndings("\n"),
                push.IsChecked == true ? remote : null);
    }

    public static async Task StashAsync(XamlRoot root, RepositoryStore store)
    {
        if (await PromptAsync(root, "Stash changes", "Message (optional)", "Stash", allowEmpty: true) is { } message)
            await store.StashPushAsync(message);
    }

    /// <summary>Explains a refused pull and offers the two safe ways forward.</summary>
    public static async Task PullBlockedAsync(XamlRoot root, RepositoryStore store, PullBlock block)
    {
        var count = block.Files.Count;
        var summary = count switch
        {
            0 => "You have uncommitted changes.",
            1 => "The incoming commits change a file you haven’t committed.",
            _ => $"The incoming commits change {count} files you haven’t committed.",
        };
        var content = new StackPanel { Spacing = 12, MinWidth = 380 };
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Text = summary + " The pull was stopped, and your files are as you left them.",
        });
        if (count > 0)
        {
            content.Children.Add(new Border
            {
                CornerRadius = new CornerRadius(8), Padding = new Thickness(12, 8, 12, 8),
                BorderThickness = new Thickness(1),
                BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(0x33, 0x80, 0x80, 0x80)),
                Child = new ScrollViewer
                {
                    MaxHeight = 150,
                    Content = new TextBlock
                    {
                        Text = string.Join("\n", block.Files), FontSize = 12, IsTextSelectionEnabled = true,
                        FontFamily = new FontFamily("Consolas"), TextWrapping = TextWrapping.Wrap,
                    },
                },
            });
        }
        content.Children.Add(new TextBlock
        {
            TextWrapping = TextWrapping.Wrap, FontSize = 12, Opacity = 0.7,
            Text = "Commit your changes, then pull again. Or stash them: they are set aside, "
                + "the commits are pulled, and your changes are put back.",
        });
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = "Commit your changes before pulling", Content = content,
            PrimaryButtonText = "Commit changes", SecondaryButtonText = "Stash and pull", CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        try
        {
            switch (await dialog.ShowAsync())
            {
                case ContentDialogResult.Primary:
                    store.Mode = StoreMode.Changes;
                    break;
                case ContentDialogResult.Secondary:
                    await store.StashAndPullAsync();
                    break;
            }
        }
        catch (Exception e)
        {
            // WinUI allows one dialog at a time; the banner still says what to do.
            Trace.TraceWarning($"Pull dialog could not be shown: {e.GetType().Name}");
            store.ErrorMessage = "The pull was stopped. Commit or stash your changes, then pull again.";
        }
    }

    /// <summary>Asks before something destructive; Cancel is the default.</summary>
    public static async Task<bool> ConfirmAsync(XamlRoot root, string title, string message, string verb)
    {
        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap },
            PrimaryButtonText = verb, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close,
        };
        try
        {
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        catch (Exception e)
        {
            // WinUI allows one dialog at a time. Not shown means not confirmed.
            Trace.TraceWarning($"Confirmation could not be shown: {e.GetType().Name}");
            return false;
        }
    }

    /// <summary>Aborting throws away conflict resolutions, so it asks first.</summary>
    public static async Task AbortAsync(XamlRoot root, RepositoryStore store, InProgressOperation operation)
    {
        var what = operation.Kind == OperationKind.Merge ? "merge" : "operation";
        if (await ConfirmAsync(root, $"Abort the {operation.Verb.ToLowerInvariant()}?",
                $"Everything done by this {what} so far, including conflict resolutions, is thrown away and the "
                    + "repository returns to how it was before.", "Abort and go back")
            && store.Operation == operation)
            await store.AbortOperationAsync();
    }

    /// <summary>Raised after text reaches the clipboard, so the window can say so.</summary>
    public static event Action? Copied;

    public static void Copy(string text)
    {
        var package = new DataPackage();
        package.SetText(text);
        Clipboard.SetContent(package);
        Copied?.Invoke();
    }

    /// <summary>Returns the trimmed text, or null when cancelled.</summary>
    internal static async Task<string?> PromptAsync(
        XamlRoot root, string title, string placeholder, string confirm, UIElement? extra = null, bool allowEmpty = false,
        string initial = "")
    {
        var input = new TextBox { PlaceholderText = placeholder, Text = initial };
        input.SelectAll();
        var content = new StackPanel { Spacing = 12, Children = { input } };
        if (extra is not null) content.Children.Add(extra);
        var dialog = new ContentDialog
        {
            // Dialogs don't inherit a theme forced on the window content.
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = title, Content = content, PrimaryButtonText = confirm, CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary, IsPrimaryButtonEnabled = allowEmpty || initial.Length > 0,
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
