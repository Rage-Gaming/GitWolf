using System.Diagnostics;
using GitWolf.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

namespace GitWolf.App.Services;

/// <summary>Clone and new-repository dialogs. Ported from CreateRepositorySheets.swift.</summary>
internal static class CreateDialogs
{
    /// <returns>The cloned folder, or null when cancelled.</returns>
    public static Task<string?> CloneAsync(XamlRoot root, IntPtr window, string? gitPath)
    {
        var url = new TextBox { Header = "Repository URL", PlaceholderText = "https://host/owner/repo.git" };
        var name = new TextBox { Header = "Folder name" };
        // The name follows the URL until the user types their own.
        var suggested = "";
        url.TextChanged += (_, _) =>
        {
            if (name.Text != suggested) return;
            name.Text = suggested = GitRepository.SuggestedName(url.Text);
        };
        var options = new CloneOptionFields();
        return ShowAsync(root, window, "Clone repository", "Clone", [url], name, () =>
        {
            var (from, folder, chosen) = (url.Text.Trim(), name.Text.Trim(), options.Read());
            return (parent, progress, token) => GitRepository.CloneAsync(
                from, parent, folder, gitPath, onProgress: progress, cancellationToken: token, options: chosen);
        }, options.View);
    }

    /// <returns>The new repository's folder, or null when cancelled.</returns>
    public static Task<string?> NewAsync(XamlRoot root, IntPtr window, string? gitPath)
    {
        var name = new TextBox { Header = "Folder name" };
        var branch = new TextBox { Header = "Initial branch", Text = "main" };
        return ShowAsync(root, window, "New repository", "Create", [], name, () =>
        {
            var (folder, initial) = (name.Text.Trim(), branch.Text);
            return (parent, _, _) => GitRepository.CreateAsync(parent, folder, initial, gitPath);
        }, branch);
    }

    /// <param name="prepare">
    /// Reads the fields on the UI thread and returns the work, which runs on another thread.
    /// </param>
    private static async Task<string?> ShowAsync(
        XamlRoot root, IntPtr window, string title, string verb, IReadOnlyList<Control> before, TextBox name,
        Func<Func<string, Action<string>, CancellationToken, Task<string>>> prepare, Control? after = null)
    {
        var location = new TextBox
        {
            Header = "Location", Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        var choose = new Button { Content = "Choose…", VerticalAlignment = VerticalAlignment.Bottom };
        var status = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, MaxHeight = 120 };
        var working = new ProgressBar { IsIndeterminate = true, Visibility = Visibility.Collapsed };
        var row = new Grid
        {
            ColumnSpacing = 8,
            ColumnDefinitions = { new ColumnDefinition(), new ColumnDefinition { Width = GridLength.Auto } },
            Children = { location, choose },
        };
        Grid.SetColumn(choose, 1);
        var content = new StackPanel { Spacing = 12, Width = 420 };
        foreach (var control in before) content.Children.Add(control);
        content.Children.Add(name);
        content.Children.Add(row);
        if (after is not null) content.Children.Add(after);
        content.Children.Add(working);
        content.Children.Add(status);

        var dialog = new ContentDialog
        {
            RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
            XamlRoot = root, Title = title, Content = new ScrollViewer { Content = content }, PrimaryButtonText = verb,
            CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary,
        };
        choose.Click += async (_, _) =>
        {
            try
            {
                var picker = new FolderPicker();
                picker.FileTypeFilter.Add("*");
                WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
                if (await picker.PickSingleFolderAsync() is { } folder) location.Text = folder.Path;
            }
            catch (Exception e)
            {
                Trace.TraceWarning($"Choosing a folder failed: {e.GetType().Name}");
                status.Text = "The folder picker couldn’t be opened. Type the location instead.";
            }
        };

        string? result = null;
        CancellationTokenSource? running = null;
        // The dialog stays open while git runs, showing progress or the failure.
        dialog.PrimaryButtonClick += async (_, e) =>
        {
            var deferral = e.GetDeferral();
            e.Cancel = true;
            try
            {
                if (running is not null) return;
                if (before.OfType<TextBox>().Any(box => box.Text.Trim().Length == 0)
                    || name.Text.Trim().Length == 0 || !Path.IsPathFullyQualified(location.Text.Trim()))
                {
                    status.Text = "Fill in every field, with a full folder path as the location.";
                    return;
                }
                running = new CancellationTokenSource();
                var token = running.Token;
                dialog.IsPrimaryButtonEnabled = false;
                working.Visibility = Visibility.Visible;
                status.Text = "";
                // Deferral ends now so Cancel keeps working while git runs.
                deferral.Complete();
                deferral = null;
                var parent = location.Text.Trim();
                void Progress(string chunk)
                {
                    var line = chunk.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).LastOrDefault();
                    if (line is not null) dialog.DispatcherQueue.TryEnqueue(() => status.Text = line);
                }
                var run = prepare();
                var folder = await Task.Run(() => run(parent, Progress, token), token);
                if (token.IsCancellationRequested) return;
                result = folder;
                dialog.Hide();
            }
            catch (OperationCanceledException)
            {
                // Cancelled by the user.
            }
            catch (Exception error)
            {
                // An event handler can't pass the failure on, so every one is shown or logged here.
                Trace.TraceWarning($"{title} failed: {error.GetType().Name}");
                var message = error is GitException or IOException or UnauthorizedAccessException
                    ? error.Message : "That didn’t work. Check the fields and try again.";
                // Posted after any queued progress, so the failure is what stays visible.
                dialog.DispatcherQueue.TryEnqueue(() => status.Text = message);
            }
            finally
            {
                deferral?.Complete();
                running?.Dispose();
                running = null;
                working.Visibility = Visibility.Collapsed;
                dialog.IsPrimaryButtonEnabled = true;
            }
        };
        dialog.CloseButtonClick += (_, _) => running?.Cancel();
        try
        {
            await dialog.ShowAsync();
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"{title} dialog could not be shown: {e.GetType().Name}");
        }
        // Escape closes without the Cancel button.
        if (result is null) running?.Cancel();
        return result;
    }
}
